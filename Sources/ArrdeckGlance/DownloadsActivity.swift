import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// What the Live Activity shows. Outside the ActivityKit guard so it builds
/// and is tested on macOS; the attributes below only wrap it.
public struct DownloadsActivityState: Codable, Hashable, Sendable {
    public var count: Int
    public var speed: Int
    public var progress: Double?
    public var eta: Int?
    /// The fastest download's name, for the expanded island and the lock screen.
    public var lead: String?
    /// When the app last updated it. Without push it cannot be updated once
    /// the app is suspended, so the time is always on show.
    public var updatedAt: Date
    public var byteBase: Int

    public init(count: Int, speed: Int, progress: Double?, eta: Int?, lead: String?, updatedAt: Date, byteBase: Int = 1024) {
        self.count = count
        self.speed = speed
        self.progress = progress
        self.eta = eta
        self.lead = lead
        self.updatedAt = updatedAt
        self.byteBase = byteBase
    }

    /// nil when nothing is downloading — the activity's cue to end.
    public init?(_ downloads: GlanceSnapshot.Downloads?, byteBase: Int) {
        guard let downloads, downloads.count > 0 else { return nil }
        self.init(count: downloads.count, speed: downloads.speed, progress: downloads.progress,
                  eta: downloads.eta, lead: downloads.top.first?.name, updatedAt: downloads.at, byteBase: byteBase)
    }

    /// Whether `other` would look the same, ignoring when it was taken: the
    /// activity is not re-sent every five-second poll for a speed that
    /// wobbled by a few kilobytes.
    public func looksLike(_ other: DownloadsActivityState) -> Bool {
        func percent(_ value: Double?) -> Int? { value.map { Int(($0 * 100).rounded(.down)) } }
        func minutes(_ value: Int?) -> Int? { value.map { $0 / 60 } }
        let speedClose = abs(speed - other.speed) <= max(speed, other.speed) / 20
        return count == other.count && lead == other.lead && byteBase == other.byteBase
            && percent(progress) == percent(other.progress) && minutes(eta) == minutes(other.eta) && speedClose
    }

    /// After this long without an update the system greys the activity and
    /// its views say so: past it, the app has been suspended too long to be
    /// keeping it current.
    public static let staleAfter: TimeInterval = 10 * 60
}

#if os(iOS) && canImport(ActivityKit)
public struct DownloadsActivityAttributes: ActivityAttributes {
    public typealias ContentState = DownloadsActivityState
    public var server: String

    public init(server: String) {
        self.server = server
    }
}
#endif
