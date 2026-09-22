import ArrdeckKit
import Foundation
import Observation

/// One profile's standing with its backend, owned above both the dashboard
/// and the connection screen so a 401 discovered by a card and a sign-in
/// completed in the web view land in the same place.
@MainActor @Observable
public final class SessionController {
    public private(set) var profile: ServerProfile
    public private(set) var session: ProfileSession = .unknown

    let transport: any HTTPTransport
    let onUpdate: (ServerProfile) -> Void

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = URLSessionTransport(),
        onUpdate: @escaping (ServerProfile) -> Void
    ) {
        self.profile = profile
        self.transport = transport
        self.onUpdate = onUpdate
    }

    /// Whether the backend answers this device's requests right now.
    public var isUsable: Bool {
        switch session {
        case .open, .paired, .legacy: true
        default: false
        }
    }

    public var canPair: Bool {
        switch session {
        case .needsPairing, .rejected: true
        default: false
        }
    }

    public func refresh() async {
        // Holding a cookie changes the question: not "is this an arrdeck" but
        // "does my session still work" — the 401 answer means signed out, not
        // pair-me.
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        if SessionCookie.match(in: cookies, for: profile.baseURL) != nil {
            await completePairing()
        } else {
            apply(SessionFlow.after(await AboutProbe.probe(profile.baseURL, transport: transport)))
        }
    }

    public func completePairing() async {
        let (next, updated) = await Pairing.complete(profile, transport: transport)
        session = next
        if updated != profile {
            profile = updated
            onUpdate(updated)
        }
    }

    /// A request that used to work answered 401: the session was revoked or
    /// expired. Reported by whichever screen noticed.
    public func sessionLost() {
        session = .rejected
    }

    func apply(_ next: ProfileSession) {
        session = next
        if let info = SessionFlow.capabilities(of: next), info != profile.lastKnown {
            profile.lastKnown = info
            onUpdate(profile)
        }
    }
}
