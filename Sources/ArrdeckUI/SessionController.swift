import ArrdeckData
import ArrdeckKit
import Foundation
import Network
import Observation

/// One profile's standing with its backend, owned above both the dashboard
/// and the connection screen so a 401 discovered by a card and a sign-in
/// completed in the browser sheet land in the same place.
@MainActor @Observable
public final class SessionController {
    public private(set) var profile: ServerProfile
    public private(set) var session: ProfileSession = .unknown
    /// Which address requests go to. Always `.primary` without a home address.
    public private(set) var route: ConnectionRoute = .primary

    let transport: any HTTPTransport
    /// For probing the home address: short timeout, no cookies.
    let homeTransport: any HTTPTransport
    let onUpdate: (ServerProfile) -> Void
    /// Shared with the API client, which reads it on every request.
    public let router: AddressRouter
    /// The latest re-check, cancelled when a newer one starts so a burst of
    /// network changes settles on the last one's answer.
    private var rerouting: Task<Void, Never>?

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = URLSessionTransport(),
        homeTransport: any HTTPTransport = URLSessionTransport(timeout: ConnectionChoice.probeTimeout, cookies: nil),
        onUpdate: @escaping (ServerProfile) -> Void
    ) {
        self.profile = profile
        self.transport = transport
        self.homeTransport = homeTransport
        self.onUpdate = onUpdate
        router = AddressRouter(primary: profile.baseURL, home: profile.homeURL)
        router.setOnFallback { [weak self] in
            Task { @MainActor in await self?.fellBack() }
        }
    }

    /// The address in use: for the API, images and file downloads. Addresses
    /// handed to other apps (calendar feeds, the book catalogue) use
    /// `profile.baseURL` instead, which works from anywhere.
    public var activeURL: URL {
        route == .home ? profile.homeURL ?? profile.baseURL : profile.baseURL
    }

    /// At home, with nothing to sign in to here, but no session yet for when
    /// the home address stops answering.
    public var needsAwaySignIn: Bool {
        route == .home && !hasPrimarySession
    }

    var hasPrimarySession: Bool {
        SessionCookie.match(in: HTTPCookieStorage.shared.cookies ?? [], for: profile.baseURL) != nil
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
        guard let home = profile.homeURL else {
            await refreshPrimary()
            return
        }
        // Both at once, so being away costs no more than the home probe's
        // short timeout; at home the primary check is cancelled unused.
        async let primary: (ProfileSession, ServerProfile) = checkPrimary()
        let outcome = await ConnectionChoice.probeHome(home, transport: homeTransport)
        if ConnectionChoice.choose(home: home, probe: outcome) == .home, case let .reachable(info) = outcome {
            use(.home)
            apply(.open(info))
            return
        }
        use(.primary)
        let (next, updated) = await primary
        settle(next, updated)
    }

    func refreshPrimary() async {
        let (next, updated) = await checkPrimary()
        settle(next, updated)
    }

    /// The primary address's standing, without touching state, so `refresh`
    /// can drop it when the home address wins.
    ///
    /// Holding a cookie changes the question: not "is this an arrdeck" but
    /// "does my session still work" — the 401 answer means signed out, not
    /// pair-me.
    func checkPrimary() async -> (ProfileSession, ServerProfile) {
        if hasPrimarySession {
            return await Pairing.complete(profile, transport: transport)
        }
        var updated = profile
        let next = SessionFlow.after(await AboutProbe.probe(profile.baseURL, transport: transport))
        if let info = SessionFlow.capabilities(of: next) { updated.lastKnown = info }
        return (next, updated)
    }

    public func completePairing() async {
        let (next, updated) = await Pairing.complete(profile, transport: transport)
        // At home the session is the home address's; a primary that cannot
        // be reached from inside the house (no hairpin NAT) must not take the
        // working screens away. The cookie is stored either way.
        if route == .home, SessionFlow.capabilities(of: next) == nil {
            return
        }
        settle(next, updated)
    }

    func settle(_ next: ProfileSession, _ updated: ServerProfile) {
        session = next
        // Only the capabilities: the rest of the profile may have changed
        // (a home address saved) while the check was in flight.
        if updated.lastKnown != profile.lastKnown {
            profile.lastKnown = updated.lastKnown
            onUpdate(profile)
        }
    }

    func use(_ next: ConnectionRoute) {
        router.use(home: next == .home)
        route = router.isHome ? .home : .primary
    }

    /// Re-picks the address when the app comes back or the network changes.
    /// Never blocks: requests keep going wherever the router points until the
    /// probe answers, and a usable session is never replaced by an
    /// unreachable one here — a network that is still coming up should not
    /// take the screens away.
    public func reroute(after delay: Duration = .zero) {
        guard profile.homeURL != nil else { return }
        rerouting?.cancel()
        rerouting = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let home = profile.homeURL else { return }
            let outcome = await ConnectionChoice.probeHome(home, transport: homeTransport)
            // a cancelled probe reads as unreachable: not an answer
            guard !Task.isCancelled else { return }
            if ConnectionChoice.choose(home: home, probe: outcome) == .home, case let .reachable(info) = outcome {
                use(.home)
                if !isUsable { apply(.open(info)) }
            } else {
                await leaveHome()
            }
        }
    }

    /// Off the home address, by probe or by a request that could not reach it.
    /// A session that only worked because the home network trusted us needs
    /// the primary's verdict: signed in, or a sign-in screen.
    func leaveHome() async {
        let wasHome = route == .home
        use(.primary)
        // `.paired` already came from the primary; `.open` reached while at
        // home came from the home address
        guard wasHome, case .open = session else { return }
        let (next, updated) = await checkPrimary()
        // no answer at all: a network still coming up, or none — the screens
        // stay and their requests say what is wrong
        if case .offline = next { return }
        settle(next, updated)
    }

    /// The router gave up on the home address mid-request.
    func fellBack() async {
        guard route == .home else { return }
        await leaveHome()
    }

    /// Saves, replaces or removes the home address, then picks again.
    public func setHomeURL(_ url: URL?) {
        profile.homeURL = url
        onUpdate(profile)
        router.setHome(url)
        if url == nil {
            rerouting?.cancel()
            Task { await leaveHome() }
        } else {
            reroute()
        }
    }

    /// Re-picks on every network change (Wi-Fi joined or left, cellular up)
    /// for as long as the calling task lives. The first path report is the
    /// current state, already handled by `refresh`. Watches even without a
    /// home address, so one added later takes effect without reopening the
    /// server; `reroute` does nothing until there is one.
    public func watchNetwork() async {
        let changes = AsyncStream<Void> { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { _ in continuation.yield() }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dk.thrawn.arrdeck.path"))
        }
        var first = true
        for await _ in changes {
            if first { first = false; continue }
            // a moment for a just-joined network to hand out an address
            reroute(after: .seconds(1))
        }
    }

    /// Redeems the code the browser sheet came back with, then reads the
    /// backend as a signed-in client.
    public func pair(code: String, request: PairingRequest) async throws {
        guard let poster = transport as? any HTTPPoster else {
            throw PairingError.unexpected(status: 0)
        }
        try await Pairing.exchange(code: code, request: request, baseURL: profile.baseURL, transport: poster)
        await completePairing()
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
