import CryptoKit
import Foundation

/// One sign-in attempt from the app: the link the browser sheet opens, and the
/// PKCE verifier that makes the code it hands back worth anything.
///
/// The app cannot run WebAuthn in a web view of its own (that needs an
/// Associated Domains entitlement per backend host, which an app pointed at
/// any server cannot have), so it signs in through the system browser sheet,
/// where passkeys work. The backend's /pair page then redirects to
/// `arrdeck://paired?code=…`. Any app may claim that scheme, so the code is
/// bound to this attempt's challenge and is redeemed only with the verifier.
public struct PairingRequest: Sendable {
    public static let callbackScheme = "arrdeck"

    public let verifier: String

    public init() {
        var rng = SystemRandomNumberGenerator()
        self.init(verifier: Self.base64url(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) })))
    }

    init(verifier: String) {
        self.verifier = verifier
    }

    /// SHA-256 of the verifier, base64url without padding. Contract with
    /// `_pkce` in backend/app/api/v1/auth.py.
    public var challenge: String {
        Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public func url(for baseURL: URL) -> URL {
        baseURL.appending(path: "pair").appending(queryItems: [URLQueryItem(name: "challenge", value: challenge)])
    }

    /// The code from the page's redirect, or nil for anything else.
    public static func code(from callback: URL) -> String? {
        guard callback.scheme == callbackScheme, callback.host() == "paired",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first { $0.name == "code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Sending JSON, for the one call that is not a GET. Separate from
/// HTTPTransport so the read-only test stubs stay as they are.
public protocol HTTPPoster: Sendable {
    func post(_ url: URL, json: Data) async throws -> (Data, Int)
}

extension URLSessionTransport: HTTPPoster {
    public func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum PairingError: Error, Equatable {
    /// The redirect did not carry a code.
    case noCode
    /// Spent, expired, or not this attempt's: sign in again.
    case refused
    /// Too many failed attempts; the backend is making everyone wait.
    case throttled
    case unexpected(status: Int)
}

public enum Pairing {
    static let exchangePath = "api/v1/auth/pair/exchange"

    /// Trades the code from the browser sheet for a session. The session
    /// cookie arrives as Set-Cookie and lands in the transport's cookie jar —
    /// HTTPCookieStorage.shared for the real one — like any other response's.
    public static func exchange(
        code: String, request: PairingRequest, baseURL: URL, transport: any HTTPPoster
    ) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": request.verifier])
        let (_, status) = try await transport.post(baseURL.appending(path: exchangePath), json: body)
        switch status {
        case 200: return
        case 401: throw PairingError.refused
        case 429: throw PairingError.throttled
        default: throw PairingError.unexpected(status: status)
        }
    }

    /// The step after a session is in hand: ask the backend what
    /// it is, and fold the answer into the stored profile.
    ///
    /// Capabilities are only written on a working read — a rejected session or
    /// a transport failure must not wipe what the profile knew, because
    /// lastKnown is what lets the UI gate features while offline.
    public static func complete(
        _ profile: ServerProfile, transport: HTTPTransport
    ) async -> (ProfileSession, ServerProfile) {
        do {
            let read = try await AboutProbe.readPaired(profile.baseURL, transport: transport)
            let session = SessionFlow.after(read)
            var updated = profile
            if let info = SessionFlow.capabilities(of: session) {
                updated.lastKnown = info
            }
            return (session, updated)
        } catch {
            return (.offline(error.localizedDescription), profile)
        }
    }
}
