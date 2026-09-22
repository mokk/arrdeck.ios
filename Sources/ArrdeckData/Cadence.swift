import Foundation

/// Poll intervals, in seconds, mirroring the PWA's. Live views alternate
/// between `fast` while a progress bar is moving and `idle` once nothing is:
/// a stack that is only seeding has nothing to animate, and the foreground
/// poll is where an open screen spends its battery.
public struct Cadence: Sendable, Equatable {
    public var fast: TimeInterval = 5
    public var idle: TimeInterval = 20
    public var medium: TimeInterval = 30
    public var slow: TimeInterval = 300
    public var recent: TimeInterval = 60
    public var trends: TimeInterval = 600

    public init() {}

    public static let standard = Cadence()

    /// Every interval multiplied — tests shrink the whole schedule at once.
    public static func scaled(by factor: Double) -> Cadence {
        var cadence = Cadence()
        cadence.fast *= factor
        cadence.idle *= factor
        cadence.medium *= factor
        cadence.slow *= factor
        cadence.recent *= factor
        cadence.trends *= factor
        return cadence
    }
}

/// Whether a live card's numbers are still changing. Progress advances in
/// these states and nowhere else: `stalled` has stopped, `seeding` is a
/// steady rate that only wiggles — both read fine at the idle cadence.
public enum Motion {
    static let movingStates: Set<String> = ["downloading", "checking"]

    /// The summary ships only the top few active torrents, so judge those.
    public static func summaryMoving(_ blocks: [TorrentClient: Block<TorrentSummary>]) -> Bool {
        blocks.values.contains { block in
            guard let summary = block.value else { return false }
            if summary.totals.dl_speed > 0 { return true }
            return (summary.active ?? []).contains { movingStates.contains($0.state) }
        }
    }

    /// An arr queue item still has bytes to fetch. An empty or fully grabbed
    /// queue is not going to change on its own.
    public static func queueMoving(_ blocks: [ArrApp: Block<[QueueItem]>]) -> Bool {
        blocks.values.contains { block in
            (block.value ?? []).contains { $0.size_left > 0 }
        }
    }

    /// A paused session's progress bar is not going anywhere.
    public static func sessionsMoving(_ block: Block<[PlaySession]>) -> Bool {
        (block.value ?? []).contains { $0.state == "playing" }
    }
}
