import Foundation

/// The server last opened, for the work that happens without a screen to
/// choose one — Siri and the Shortcuts app ask about "arrdeck", not about a
/// particular server.
public enum LastProfile {
    static let key = "profiles.lastUsed"

    public static func record(_ profile: ServerProfile, defaults: UserDefaults = .standard) {
        defaults.set(profile.id.uuidString, forKey: key)
    }

    /// The last one opened if it still exists, else the only one; with
    /// several and no record there is no honest guess.
    public static func pick(from profiles: [ServerProfile], defaults: UserDefaults = .standard) -> ServerProfile? {
        if let raw = defaults.string(forKey: key), let match = profiles.first(where: { $0.id.uuidString == raw }) {
            return match
        }
        return profiles.count == 1 ? profiles.first : nil
    }
}
