import Foundation

/// Which of a profile's two addresses requests go to.
public enum ConnectionRoute: Equatable, Sendable {
    /// The home address answered: on the home network, no sign-in.
    case home
    /// `baseURL`: away from home, or a profile without a home address.
    case primary
}

/// Picking between a profile's home and primary address.
public enum ConnectionChoice {
    /// Short on purpose: on the home network the backend answers in
    /// milliseconds, and away from it a private address either fails at once
    /// or hangs until this runs out. Every second here is a second of the
    /// app talking to nothing after walking out of the door.
    public static let probeTimeout: TimeInterval = 1.5

    /// Pure so every branch is testable without a network.
    ///
    /// Only `.reachable` counts. A 401 from the home address means the backend
    /// does not see this caller as local — a guest network, a VPN — and no
    /// cookie is ever scoped to that host, so choosing it would fail every
    /// request. Anything short of a working answer means the primary address.
    public static func choose(home: URL?, probe: ProbeOutcome?) -> ConnectionRoute {
        guard home != nil, case .reachable = probe else { return .primary }
        return .home
    }

    /// The probe against the home address. No cookie jar: the home address
    /// needs none, and the shared jar's session belongs to the primary host.
    public static func probeHome(
        _ home: URL,
        transport: HTTPTransport = URLSessionTransport(timeout: probeTimeout, cookies: nil)
    ) async -> ProbeOutcome {
        await AboutProbe.probe(home, transport: transport)
    }
}
