import ArrdeckAPI
import Foundation
import OpenAPIRuntime

public typealias WantedItem = Components.Schemas.WantedItemOut
public typealias WantedPage = Components.Schemas.WantedPageOut
public typealias Diagnosis = Components.Schemas.DiagnosisOut
public typealias DiagnosisFinding = Components.Schemas.DiagnosisFindingOut

public enum WantedKind: String, CaseIterable, Sendable, Hashable {
    case missing
    case cutoff

    public var label: String {
        switch self {
        case .missing: String(localized: "Missing")
        case .cutoff: String(localized: "Upgrades")
        }
    }
}

extension WantedItem {
    /// The library title this wanted row belongs to — the movie itself, or the
    /// series an episode is part of.
    public var ref: MediaRef? { MediaRef(app: app.rawValue, id: library_id) }
}

extension DiagnosisFinding {
    /// The backend's params are heterogeneous display material (`Any`), so
    /// they arrive as an object container; flatten to strings for templating.
    public var parameters: [String: String] {
        guard let raw = params?.additionalProperties.value else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case let string as String: out[key] = string
            case let bool as Bool: out[key] = bool ? "yes" : "no"
            case let int as Int: out[key] = String(int)
            case let double as Double: out[key] = double.formatted(.number.precision(.fractionLength(0...1)))
            case let any?: out[key] = String(describing: any)
            case nil: break
            }
        }
        return out
    }
}

/// The wording for each diagnosis code. The endpoint returns codes rather than
/// sentences so the words can live in the locale files; until phase H they
/// live here in English. An unknown code falls back to the code itself,
/// which beats an empty row.
public enum DiagnosisText {
    static var templates: [String: String] { [
        "queue_downloading": String(localized: "It is downloading now ({state})."),
        "queue_stalled": String(localized: "The download has stalled ({state}) — no data is moving."),
        "queue_importing": String(localized: "Downloaded, waiting to be imported."),
        "queue_failed": String(localized: "The download failed and is stuck in the queue: {reason}"),
        "not_monitored": String(localized: "It is not monitored, so nothing will search for it."),
        "not_yet_available": String(localized: "Not out yet — the arr waits until it is {availability}."),
        "not_yet_available_dated": String(localized: "Not out yet — the arr waits until it is {availability}, expected {date}."),
        "blocklisted": String(localized: "A release was grabbed and rejected, so it will not be tried again: {release} from {indexer}."),
        "rss_overdue": String(localized: "RSS sync is {minutes} minutes overdue, so nothing new is being picked up."),
        "rss_stale": String(localized: "RSS sync last ran {minutes} minutes ago."),
        "delay_profile": String(localized: "A delay profile is holding grabs on purpose — usenet {usenet}m, torrent {torrent}m."),
        "no_indexers": String(localized: "No indexers are enabled, so there is nowhere to search."),
        "indexers_failing": String(localized: "{count} indexer problem reported: {message}"),
    ] }

    public static var nothingFound: String { String(localized: "Everything checks out — the indexers simply have not offered a matching release yet.") }

    public static func sentence(for finding: DiagnosisFinding) -> String {
        let params = finding.parameters
        // A release date is often unknown for an announced film, so the dated
        // and undated sentences are separate rather than one with a gap.
        let code = finding.code == "not_yet_available" && params["date"] != nil
            ? "not_yet_available_dated" : finding.code
        guard var text = templates[code] else { return finding.code }
        for (key, value) in params {
            text = text.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return text
    }
}

public protocol WantedAPI: Sendable {
    func wanted(_ app: ArrApp, kind: WantedKind, page: Int) async throws -> WantedPage
    func searchAllWanted(_ app: ArrApp, kind: WantedKind) async throws
    func diagnose(_ app: ArrApp, id: Int) async throws -> Diagnosis
    func triggerSearch(_ ref: MediaRef) async throws
    func searchEpisodes(_ ids: [Int]) async throws
}

extension LiveAPI: WantedAPI {
    public func wanted(_ app: ArrApp, kind: WantedKind, page: Int) async throws -> WantedPage {
        try await call {
            switch try await client.wanted_api_v1_wanted__app__get(
                path: .init(app: app.rawValue), query: .init(kind: kind.rawValue, page: page)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func searchAllWanted(_ app: ArrApp, kind: WantedKind) async throws {
        try await call {
            switch try await client.wanted_search_all_api_v1_wanted__app__search_all_post(
                path: .init(app: app.rawValue), query: .init(kind: kind.rawValue)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func diagnose(_ app: ArrApp, id: Int) async throws -> Diagnosis {
        try await call {
            switch try await client.diagnose_api_v1_diagnose__app___item_id__get(
                path: .init(app: app.rawValue, item_id: id)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// One arr's wanted list under one filter, paged. Changing either resets the
/// list; paging appends. Not polled — the page is opened deliberately and the
/// answer is cached server-side.
@MainActor @Observable
public final class WantedModel {
    public let apps: [ArrApp]
    public var app: ArrApp {
        didSet { if app != oldValue { Task { await load(reset: true) } } }
    }
    public var kind: WantedKind = .missing {
        didSet { if kind != oldValue { Task { await load(reset: true) } } }
    }

    public private(set) var items: [WantedItem] = []
    public private(set) var total = 0
    public private(set) var hasMore = false
    public private(set) var loading = false
    public private(set) var error: String?
    public var actionError: String?
    public private(set) var pending: Set<String> = []

    private let api: any WantedAPI
    private let onSessionLost: @MainActor () -> Void
    private var page = 1
    private var generation = 0

    public init(api: any WantedAPI, apps: [ArrApp], onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.apps = apps
        self.app = apps.first ?? .radarr
        self.onSessionLost = onSessionLost
    }

    public func isPending(_ key: String) -> Bool { pending.contains(key) }

    public func load(reset: Bool = false) async {
        if reset {
            page = 1
            items = []
            total = 0
            hasMore = false
        }
        generation += 1
        let mine = generation
        let (app, kind, page) = (app, kind, page)
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let result = try await api.wanted(app, kind: kind, page: page)
            guard mine == generation else { return }
            items = page == 1 ? result.items : items + result.items
            total = result.total ?? items.count
            hasMore = result.has_more ?? false
            error = nil
        } catch {
            guard mine == generation else { return }
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            self.error = describe(error)
        }
    }

    public func loadMore() async {
        guard hasMore, !loading else { return }
        page += 1
        await load()
    }

    public func searchAll() async {
        await perform("search-all") { try await api.searchAllWanted(app, kind: kind) }
    }

    /// Radarr wants the movie searched; Sonarr wants the episode.
    public func search(_ item: WantedItem) async {
        await perform("search-\(item.id)") {
            switch item.app {
            case .radarr: try await api.triggerSearch(.movie(item.id))
            case .sonarr: try await api.searchEpisodes([item.id])
            }
        }
    }

    /// The diagnosis is per library title: the backend matches the queue on
    /// movie_id / series_id and 404s for an episode id. (The PWA passed the
    /// episode id for Sonarr rows, which is how this was found.)
    public func diagnose(_ item: WantedItem) async throws -> Diagnosis {
        try await api.diagnose(item.ref?.app ?? .radarr, id: item.library_id)
    }

    private func perform(_ key: String, _ work: @Sendable () async throws -> Void) async {
        pending.insert(key)
        defer { pending.remove(key) }
        do {
            try await work()
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }
}
