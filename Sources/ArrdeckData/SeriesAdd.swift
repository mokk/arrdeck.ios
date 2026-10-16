import ArrdeckAPI
import Foundation

/// Which episodes of a new show Sonarr monitors: one of Sonarr's presets, or
/// exactly the seasons picked.
public enum SeriesMonitor: String, CaseIterable, Sendable {
    case all, future, missing, existing, recent, pilot, firstSeason, lastSeason, none, pick

    public var label: String {
        switch self {
        case .all: String(localized: "All episodes")
        case .future: String(localized: "Future episodes")
        case .missing: String(localized: "Missing episodes")
        case .existing: String(localized: "Existing episodes")
        case .recent: String(localized: "Recent episodes")
        case .pilot: String(localized: "Pilot episode")
        case .firstSeason: String(localized: "First season")
        case .lastSeason: String(localized: "Latest season")
        case .none: String(localized: "None")
        case .pick: String(localized: "Pick seasons…")
        }
    }
}

/// Adding a show with a choice of what to monitor.
public protocol SeriesAddAPI: Sendable {
    /// The season numbers a show has (0 is specials), before it is added.
    func seriesSeasons(tvdbID: Int) async throws -> [Int]
    /// `seasons` set: exactly those monitored, and `monitor` is ignored.
    func addSeries(_ result: SearchResult, qualityProfile: Int, rootFolder: String,
                   monitor: SeriesMonitor, seasons: [Int]?) async throws
}

/// The rules the add sheet follows for a picked set of seasons.
public enum SeriesMonitorPick {
    /// Every regular season, which is where a fresh pick starts.
    public static func initial(_ seasons: [Int]) -> Set<Int> { Set(seasons.filter { $0 > 0 }) }

    /// Monitoring nothing leaves nothing to search for yet.
    public static func searches(monitor: SeriesMonitor, seasons: [Int]?) -> Bool {
        if let seasons { return !seasons.isEmpty }
        return monitor != .none
    }
}
