import ArrdeckAPI
import Foundation
import Observation

public typealias HistoryPage = Components.Schemas.HistoryPageOut
public typealias BlocklistPage = Components.Schemas.BlocklistPageOut
public typealias BlocklistItem = Components.Schemas.BlocklistItemOut

public protocol HistoryAPI: Sendable {
    func historyPage(_ page: Int) async throws -> HistoryPage
    func blocklist() async throws -> BlocklistPage
    func removeFromBlocklist(_ app: ArrApp, id: Int) async throws
    func clearBlocklist(_ app: ArrApp) async throws
    func statsHistory(days: Int) async throws -> [StatsSample]
}

extension LiveAPI: HistoryAPI {
    public func historyPage(_ page: Int) async throws -> HistoryPage {
        try await call {
            switch try await client.history_all_api_v1_history_all_get(query: .init(page: page)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func blocklist() async throws -> BlocklistPage {
        try await call {
            switch try await client.blocklist_api_v1_blocklist_get() {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func removeFromBlocklist(_ app: ArrApp, id: Int) async throws {
        try await call {
            switch try await client.blocklist_remove_api_v1_blocklist__app___entry_id__delete(
                path: .init(app: app.rawValue, entry_id: id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func clearBlocklist(_ app: ArrApp) async throws {
        try await call {
            switch try await client.blocklist_clear_api_v1_blocklist__app__delete(path: .init(app: app.rawValue)) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// The history event types worth filtering on, as the PWA's chips.
public let historyEventTypes = ["fetched", "imported", "failed", "deleted"]

/// Merged history across both arrs, paged with append; filters are local
/// because every page is already on the device.
@MainActor @Observable
public final class HistoryModel {
    public var appFilter: ArrApp?
    public var eventFilter: String?
    public private(set) var items: [HistoryItem] = []
    public private(set) var hasMore = false
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var blocklist: Loadable<[BlocklistItem]> = .loading
    public var actionError: String?
    public private(set) var busy = false

    private let api: any HistoryAPI
    private let onSessionLost: @MainActor () -> Void
    private var page = 0

    public init(api: any HistoryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var shown: [HistoryItem] {
        items.filter { item in
            (appFilter == nil || item.app.rawValue == appFilter!.rawValue)
                && (eventFilter == nil || (item.events ?? []).contains { $0._type == eventFilter })
        }
    }

    /// Which arrs have blocklist entries, for the per-arr clear buttons.
    public var blockedApps: [ArrApp] {
        ArrApp.allCases.filter { app in (blocklist.value ?? []).contains { $0.app.rawValue == app.rawValue } }
    }

    public func load() async {
        page = 0
        items = []
        await loadMore()
    }

    public func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.historyPage(page + 1)
            page += 1
            items = page == 1 ? result.items : items + result.items
            hasMore = result.has_more ?? false
            error = nil
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }

    public func loadBlocklist() async {
        do {
            blocklist = .loaded(try await api.blocklist().items ?? [])
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if blocklist.value == nil { blocklist = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    /// Releases arrdeck's own blocklist-and-retry sent here. Without this the
    /// list only ever grew, and a mistakenly blocked release stayed blocked.
    public func unblock(_ item: BlocklistItem) async {
        guard let app = ArrApp(rawValue: item.app.rawValue) else { return }
        await perform { try await api.removeFromBlocklist(app, id: item.id) }
        await loadBlocklist()
    }

    public func clearBlocklist(_ app: ArrApp) async {
        await perform { try await api.clearBlocklist(app) }
        await loadBlocklist()
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

// MARK: - Stats

public enum StatsWindow: Int, CaseIterable, Sendable, Hashable {
    case month = 30, quarter = 90, year = 365

    public var label: String {
        switch self {
        case .month: String(localized: "30 days")
        case .quarter: String(localized: "90 days")
        case .year: String(localized: "1 year")
        }
    }
}

/// One chart on the stats page: a metric over the sampled window.
public struct StatsSeries: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let values: [Double]
    public let format: @Sendable (Double) -> String

    public var first: Double { values.first ?? 0 }
    public var last: Double { values.last ?? 0 }
    public var delta: Double { last - first }
    public var min: Double { values.min() ?? 0 }
    public var max: Double { values.max() ?? 0 }
}

public enum StatsSeriesBuilder {
    /// The eight metrics the PWA charts, in its order. Torrents sums both
    /// clients; every field is optional and a snapshot taken while an arr was
    /// down reads as zero rather than a hole.
    public static func series(from samples: [StatsSample], locale: Locale = .current) -> [StatsSeries] {
        let bytes: @Sendable (Double) -> String = { Format.bytes(Int($0), locale: locale) }
        let count: @Sendable (Double) -> String = { String(Int($0.rounded())) }
        return [
            StatsSeries(id: "library", label: String(localized: "Library size"), values: samples.map { Double($0.library_bytes ?? 0) }, format: bytes),
            StatsSeries(id: "free", label: String(localized: "Free space"), values: samples.map { Double($0.disk_free_bytes ?? 0) }, format: bytes),
            StatsSeries(id: "movies", label: String(localized: "Movies"), values: samples.map { Double($0.movies ?? 0) }, format: count),
            StatsSeries(id: "series", label: String(localized: "Series"), values: samples.map { Double($0.series ?? 0) }, format: count),
            StatsSeries(id: "episodes", label: String(localized: "Episode files"), values: samples.map { Double($0.episode_files ?? 0) }, format: count),
            StatsSeries(id: "torrents", label: String(localized: "Torrents"), values: samples.map { Double(($0.torrents_qbit ?? 0) + ($0.torrents_tm ?? 0)) }, format: count),
            StatsSeries(id: "grabs", label: String(localized: "Grabs"), values: samples.map { Double($0.indexer_grabs ?? 0) }, format: count),
            StatsSeries(id: "queries", label: String(localized: "Queries"), values: samples.map { Double($0.indexer_queries ?? 0) }, format: count),
        ]
    }
}

@MainActor @Observable
public final class StatsModel {
    public var window: StatsWindow = .month {
        didSet { if window != oldValue { Task { await load() } } }
    }
    public private(set) var samples: Loadable<[StatsSample]> = .loading

    private let api: any HistoryAPI
    private let onSessionLost: @MainActor () -> Void
    private var generation = 0

    public init(api: any HistoryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var series: [StatsSeries] {
        guard let samples = samples.value, samples.count >= 2 else { return [] }
        return StatsSeriesBuilder.series(from: samples)
    }

    public var range: (Date, Date)? {
        guard let samples = samples.value, let first = samples.first, let last = samples.last else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(first.ts)), Date(timeIntervalSince1970: TimeInterval(last.ts)))
    }

    public func load() async {
        generation += 1
        let mine = generation
        let days = window.rawValue
        do {
            let result = try await api.statsHistory(days: days)
            guard mine == generation else { return }
            samples = .loaded(result)
        } catch {
            guard mine == generation else { return }
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if samples.value == nil { samples = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }
}
