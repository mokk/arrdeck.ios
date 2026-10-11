import Foundation

/// The snapshot file in the container the app shares with its widgets.
///
/// The App Group is the one capability here a free (Personal Team) signature
/// may not grant. Without it the container URL is nil on a device, and then
/// the store is simply unavailable: the app writes nothing and carries on,
/// and the widgets show "Open arrdeck to load". The container URL is the
/// only test of that — `UserDefaults(suiteName:)` returns an object even when
/// the entitlement is missing, and would quietly store into the app's own
/// defaults where the widget can never read it.
public struct GlanceStore: Sendable {
    /// Must match `com.apple.security.application-groups` in
    /// App/AppGroup.entitlements. nil turns the shared snapshot off entirely.
    public static let appGroup: String? = "group.dk.thrawn.arrdeck"

    static let fileName = "glance.json"

    /// nil: no shared container, so nothing to read or write.
    public let fileURL: URL?
    /// Small poster copies for the Activity widget, named by an entry's key.
    public let postersURL: URL?

    public init(appGroup: String? = GlanceStore.appGroup) {
        let container = appGroup.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        self.init(directory: container)
    }

    /// For tests: any directory, or nil for a device without the App Group.
    public init(directory: URL?) {
        fileURL = directory?.appending(path: Self.fileName)
        postersURL = directory?.appending(path: "posters", directoryHint: .isDirectory)
    }

    /// Where the poster for an Activity entry's `key` is kept.
    public func posterURL(_ key: String) -> URL? {
        postersURL?.appending(path: key + ".jpg")
    }

    public var isAvailable: Bool { fileURL != nil }

    /// nil when there is no container, no file yet, or a file this build
    /// cannot read — every one of them the same "Open arrdeck" to a widget.
    public func read() -> GlanceSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return Self.decode(data)
    }

    /// False when there is nowhere to write; the app has nothing to do about it.
    @discardableResult
    public func write(_ snapshot: GlanceSnapshot) -> Bool {
        guard let fileURL, let data = try? Self.encode(snapshot) else { return false }
        // atomic: a widget reading mid-write must see the old copy or the new, never half
        return (try? data.write(to: fileURL, options: [.atomic])) != nil
    }

    public static func encode(_ snapshot: GlanceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) -> GlanceSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(GlanceSnapshot.self, from: data),
              snapshot.version == GlanceSnapshot.currentVersion
        else { return nil }
        return snapshot
    }
}
