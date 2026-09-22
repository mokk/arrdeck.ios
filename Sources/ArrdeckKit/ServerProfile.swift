import Foundation

/// One arrdeck deployment the app knows about.
public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    /// Immutable by design. Sessions are cookies and passkeys are rp_id-scoped,
    /// so a different URL is a different identity — an "edit URL" affordance
    /// would silently invalidate both and present it as the same server.
    /// Changing the address means creating a new profile and pairing again.
    public let baseURL: URL

    public var name: String

    /// What the backend reported the last time it was asked. Cached so the UI
    /// can gate features while offline instead of flashing everything on and
    /// off with connectivity.
    public var lastKnown: BackendInfo?

    public init(id: UUID = UUID(), baseURL: URL, name: String, lastKnown: BackendInfo? = nil) {
        self.id = id
        self.baseURL = baseURL
        self.name = name
        self.lastKnown = lastKnown
    }
}

/// The identity and capabilities a backend reports from /api/v1/about.
public struct BackendInfo: Codable, Hashable, Sendable {
    public let version: String
    /// Feature names as the backend sent them. Kept as raw strings so a newer
    /// backend's unknown features survive a round-trip through storage instead
    /// of being dropped by an enum this build has never heard of.
    public let features: Set<String>

    public init(version: String, features: Set<String>) {
        self.version = version
        self.features = features
    }

    /// A backend from before /api/v1/about existed. It answers requests but can
    /// not describe itself, so the UI shows only what every version has had.
    public static let legacy = BackendInfo(version: "", features: [])

    public func supports(_ feature: Feature) -> Bool {
        features.contains(feature.rawValue)
    }
}

/// The capabilities the app gates UI on. Raw values are the contract with the
/// backend's FEATURE_ROUTES table — checked against the committed OpenAPI spec
/// by AboutContractTests rather than trusted to stay aligned.
public enum Feature: String, CaseIterable, Sendable {
    case diagnose
    case credits
    case qualityProfiles = "quality_profiles"
    case scheduledTasks = "scheduled_tasks"
    case arrBackups = "arr_backups"
    case blocklist
    case push
    case passkeys
    case popular
    case calendar
    case wanted
    case manualImport = "manual_import"
    case interactiveSearch = "interactive_search"
    case subtitles
    case vpn
    case backupRestore = "backup_restore"
}
