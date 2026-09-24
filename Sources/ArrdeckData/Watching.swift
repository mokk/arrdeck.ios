import ArrdeckAPI
import Foundation

public typealias WatchStats = Components.Schemas.WatchStatsOut
public typealias WatchTitle = Components.Schemas.WatchTitleOut

extension Components.Schemas.ServiceBlock_WatchStatsOut_: ServiceBlockShape {}

/// Plex's play history as statistics, and the plex.tv watchlist.
public protocol WatchingAPI: Sendable {
    /// `days` 0 is all time; weekdays and hours are counted in `timeZone`.
    func watchStats(days: Int, timeZone: String) async throws -> Block<WatchStats>
    /// As search results, so the add sheet takes them as they are.
    func plexWatchlist() async throws -> [SearchResult]
}

extension LiveAPI: WatchingAPI {
    public func watchStats(days: Int, timeZone: String) async throws -> Block<WatchStats> {
        try await call {
            switch try await client.watch_stats_api_v1_plex_stats_get(query: .init(days: days, tz: timeZone)) {
            case let .ok(ok): Block(try ok.body.json)
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func plexWatchlist() async throws -> [SearchResult] {
        try await call {
            switch try await client.plex_watchlist_api_v1_plex_watchlist_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// The periods the Watching view offers; 0 days is all time.
public enum WatchWindow: Int, CaseIterable, Sendable {
    case week = 7, month = 30, year = 365, all = 0

    public var label: String {
        switch self {
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .year: String(localized: "1 year")
        case .all: String(localized: "All time")
        }
    }
}

extension WatchStats {
    /// Index of the busiest bucket, or nil when nothing was watched.
    public static func peak(_ values: [Int]) -> Int? {
        guard let top = values.max(), top > 0 else { return nil }
        return values.firstIndex(of: top)
    }
}
