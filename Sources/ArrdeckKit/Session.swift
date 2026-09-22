import Foundation

/// Where a profile stands with its backend. One value drives the whole UI:
/// which screen to show, whether to offer pairing, whether features are known.
public enum ProfileSession: Equatable, Sendable {
    case unknown
    /// Reachable without auth — a LAN caller. No pairing to offer.
    case open(BackendInfo)
    /// An arrdeck that answered 401 and has not been paired yet.
    case needsPairing
    /// Paired, capabilities in hand.
    case paired(BackendInfo)
    /// Paired against a backend from before /about existed: works, minimal set.
    case legacy
    /// A session that used to work answered 401 — revoked or expired. Distinct
    /// from needsPairing so the UI can say "signed out" rather than "new".
    case rejected
    case offline(String)
    case notArrdeck(String)
}

/// The transitions, kept pure so the pairing web-view layer stays a thin shell.
public enum SessionFlow {
    /// From the onboarding probe (no credentials in play).
    public static func after(_ outcome: ProbeOutcome) -> ProfileSession {
        switch outcome {
        case let .reachable(info): .open(info)
        case .needsPairing: .needsPairing
        case let .notArrdeck(reason): .notArrdeck(reason)
        case let .unreachable(reason): .offline(reason)
        }
    }

    /// From re-reading /about once a session cookie is held.
    public static func after(_ read: PairedAbout) -> ProfileSession {
        switch read {
        case let .current(info): .paired(info)
        case .legacy: .legacy
        case .sessionRejected: .rejected
        }
    }

    /// What the UI can rely on, if anything. `open`, `paired` and `legacy` are
    /// the three working states; legacy works with the empty feature set.
    public static func capabilities(of session: ProfileSession) -> BackendInfo? {
        switch session {
        case let .open(info), let .paired(info): info
        case .legacy: .legacy
        case .unknown, .needsPairing, .rejected, .offline, .notArrdeck: nil
        }
    }
}

/// The backend's session cookie, as the pairing web view hands it over.
public enum SessionCookie {
    /// The name the backend sets. Contract with backend/app/api/v1/auth.py.
    public static let name = "arrdeck_session"

    /// Picks the session cookie for a profile out of a cookie-store dump.
    ///
    /// Matched on name and host, not on the store being clean: the shared
    /// WKWebsiteDataStore accumulates cookies from every profile ever paired,
    /// and handing profile A's cookie to profile B would "work" until the
    /// backend rejected it in a way the UI reads as a dead session on A.
    public static func match(in cookies: [HTTPCookie], for baseURL: URL) -> HTTPCookie? {
        guard let host = baseURL.host() else { return nil }
        return cookies.first { $0.name == name && $0.domain == host }
    }
}
