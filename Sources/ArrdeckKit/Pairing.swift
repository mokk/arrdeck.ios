import Foundation

/// Watches cookie-store dumps for the moment a session cookie appears.
///
/// The web view's cookie store fires its observer for every cookie change on
/// every site the store has seen, repeatedly. This reduces that stream to the
/// single event pairing cares about: fires once, only for this profile's host,
/// and never again — the caller tears the web view down on that signal, and a
/// second fire would tear down whatever replaced it.
public final class PairingWatcher: @unchecked Sendable {
    private let baseURL: URL
    private var fired = false
    private let lock = NSLock()

    public init(for baseURL: URL) {
        self.baseURL = baseURL
    }

    public func observe(_ cookies: [HTTPCookie]) -> HTTPCookie? {
        lock.withLock {
            guard !fired, let match = SessionCookie.match(in: cookies, for: baseURL) else {
                return nil
            }
            fired = true
            return match
        }
    }
}

public enum Pairing {
    /// The step after the web view hands over a session: ask the backend what
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
