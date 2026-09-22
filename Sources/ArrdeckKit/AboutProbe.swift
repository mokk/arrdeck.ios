import Foundation

/// What probing a base URL can honestly conclude.
///
/// /api/v1/about sits behind the same auth as everything else, and every
/// /api/v1/* path on any arrdeck answers 401 from off the LAN — so a 401 proves
/// "an arrdeck that wants pairing" but says nothing about which version. An
/// unknown path falls through to the SPA and returns 200 HTML, so a 200 is only
/// meaningful when the body parses as an arrdeck about-document.
public enum ProbeOutcome: Equatable, Sendable {
    /// 200 with a JSON body naming itself arrdeck: a LAN caller, no pairing
    /// needed, capabilities in hand.
    case reachable(BackendInfo)
    /// 401: this is an arrdeck (or at least its auth middleware); pair, then
    /// ask again.
    case needsPairing
    /// Anything else, including 200 HTML. The reason is shown to the user.
    case notArrdeck(reason: String)
    /// The transport failed before any HTTP answer existed.
    case unreachable(reason: String)
}

/// What re-reading /about *after* pairing can conclude.
public enum PairedAbout: Equatable, Sendable {
    case current(BackendInfo)
    /// 200 HTML after a successful pairing: the SPA fallback answered, so this
    /// backend predates /about. Old, not broken — gate to the legacy set.
    case legacy
    /// Still 401 with a session: the session died or was revoked.
    case sessionRejected
}

public enum AboutProbe {
    static let aboutPath = "/api/v1/about"

    /// The onboarding interpretation. Pure so every branch is testable without
    /// a network.
    public static func interpret(status: Int, body: Data) -> ProbeOutcome {
        switch status {
        case 200:
            guard let info = parseAbout(body) else {
                return .notArrdeck(reason: reasonForUnparseable(body))
            }
            return .reachable(info)
        case 401:
            return .needsPairing
        default:
            return .notArrdeck(reason: "HTTP \(status)")
        }
    }

    /// The post-pairing interpretation, where 200 HTML changes meaning: it is
    /// no longer "not an arrdeck" — pairing already proved it is one — but a
    /// backend from before /about existed.
    public static func interpretPaired(status: Int, body: Data) -> PairedAbout {
        switch status {
        case 200:
            guard let info = parseAbout(body) else { return .legacy }
            return .current(info)
        case 401:
            return .sessionRejected
        default:
            // A proxy hiccup or a mid-upgrade backend. Legacy is the safe
            // reading: the UI under-promises rather than errors.
            return .legacy
        }
    }

    static func parseAbout(_ body: Data) -> BackendInfo? {
        struct About: Decodable {
            let name: String
            let version: String
            let features: [String]
        }
        guard let about = try? JSONDecoder().decode(About.self, from: body),
              about.name == "arrdeck"
        else { return nil }
        return BackendInfo(version: about.version, features: Set(about.features))
    }

    static func reasonForUnparseable(_ body: Data) -> String {
        let prefix = String(decoding: body.prefix(64), as: UTF8.self)
        if prefix.lowercased().contains("<!doctype") || prefix.lowercased().contains("<html") {
            return "got a web page, not an API"
        }
        return "not an arrdeck response"
    }
}

/// The one seam between the kit and the network, so the probe's behaviour is
/// tested against canned responses rather than a live server.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    /// Short timeout on purpose: this backs an interactive "is this a server?"
    /// probe, and iOS's two silent failure modes here (ATS refusing plain HTTP,
    /// the local-network permission not yet granted) both present as a hang.
    /// Ten seconds of spinner is the difference between "denied" and "broken".
    ///
    /// Ephemeral for cache but wired to the shared cookie jar: the session
    /// cookie the pairing web view captures lands in HTTPCookieStorage.shared,
    /// and every subsequent call must carry it or a paired backend answers 401.
    public init(timeout: TimeInterval = 10, cookies: HTTPCookieStorage? = .shared) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = cookies
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

public extension AboutProbe {
    static func probe(_ baseURL: URL, transport: HTTPTransport) async -> ProbeOutcome {
        let url = baseURL.appending(path: aboutPath)
        do {
            let (body, status) = try await transport.get(url)
            return interpret(status: status, body: body)
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    static func readPaired(_ baseURL: URL, transport: HTTPTransport) async throws -> PairedAbout {
        let url = baseURL.appending(path: aboutPath)
        let (body, status) = try await transport.get(url)
        return interpretPaired(status: status, body: body)
    }
}
