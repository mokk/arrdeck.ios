import ArrdeckAPI
import Foundation
import Observation

public typealias CleanupLists = Components.Schemas.CleanupOut
public typealias CleanupItem = Components.Schemas.CleanupItemOut
public typealias RequestState = Components.Schemas.RequestStateOut

/// The cleanup assistant: four lists of what could go, and a delete that
/// removes the files and can keep the arrs' import lists from re-adding them.
public protocol CleanupAPI: Sendable {
    func cleanup(watchedDays: Int) async throws -> CleanupLists
    func deleteForCleanup(_ app: ArrApp, ids: [Int], exclude: Bool) async throws
}

/// Open Overseerr requests keyed for the library: "movie:tmdb:1", "tv:tvdb:2".
public protocol RequestsMapAPI: Sendable {
    func requestMap() async throws -> [String: RequestState]
}

extension LiveAPI: CleanupAPI, RequestsMapAPI {
    public func cleanup(watchedDays: Int) async throws -> CleanupLists {
        try await call {
            switch try await client.cleanup_api_v1_cleanup_get(query: .init(watched_days: watchedDays)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func deleteForCleanup(_ app: ArrApp, ids: [Int], exclude: Bool) async throws {
        try await call {
            switch try await client.library_bulk_delete_api_v1_library__kind__bulk_delete_post(
                path: .init(kind: app.libraryKind), body: .json(.init(delete_files: true, exclude: exclude, ids: ids))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func requestMap() async throws -> [String: RequestState] {
        try await call {
            switch try await client.request_map_api_v1_requests_map_get() {
            case let .ok(ok): try ok.body.json.data?.additionalProperties ?? [:]
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

public enum RequestLookup {
    public static func find(_ map: [String: RequestState], movieTMDB: Int? = nil, showTVDB: Int? = nil, showTMDB: Int? = nil) -> RequestState? {
        if let movieTMDB, let hit = map["movie:tmdb:\(movieTMDB)"] { return hit }
        if let showTVDB, let hit = map["tv:tvdb:\(showTVDB)"] { return hit }
        if let showTMDB, let hit = map["tv:tmdb:\(showTMDB)"] { return hit }
        return nil
    }
}

extension CleanupItem {
    public var key: String { "\(kind.rawValue):\(id)" }
    public var ref: MediaRef { kind == .movie ? .movie(id) : .series(id) }
}

@MainActor @Observable
public final class CleanupModel {
    public enum List: String, CaseIterable, Sendable {
        case watched, neverWatched, largest, unmonitored

        public var label: String {
            switch self {
            case .watched: String(localized: "Watched")
            case .neverWatched: String(localized: "Never watched")
            case .largest: String(localized: "Largest")
            case .unmonitored: String(localized: "Unmonitored")
            }
        }
    }

    public var list: List = .watched
    public var watchedDays = 30 {
        didSet { if watchedDays != oldValue { Task { await load() } } }
    }
    public private(set) var lists: Loadable<CleanupLists> = .loading
    public private(set) var picked: [String: CleanupItem] = [:]
    public private(set) var busy = false
    public var error: String?
    private let api: any CleanupAPI

    public init(api: any CleanupAPI) { self.api = api }

    public func rows(_ list: List) -> [CleanupItem] {
        guard let lists = lists.value else { return [] }
        return switch list {
        case .watched: lists.watched ?? []
        case .neverWatched: lists.never_watched ?? []
        case .largest: lists.largest ?? []
        case .unmonitored: lists.unmonitored ?? []
        }
    }

    public static func total(_ items: [CleanupItem]) -> Int { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var chosen: [CleanupItem] { Array(picked.values) }

    public func toggle(_ item: CleanupItem) {
        if picked[item.key] == nil { picked[item.key] = item } else { picked[item.key] = nil }
    }

    public func load() async {
        do { lists = .loaded(try await api.cleanup(watchedDays: watchedDays)) } catch {
            lists = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }

    /// Deletes the ticked titles with their files, films and shows through
    /// their own arr, then reloads the lists.
    public func deleteChosen(exclude: Bool) async {
        let items = chosen
        busy = true
        defer { busy = false }
        do {
            let movies = items.filter { $0.kind == .movie }.map(\.id)
            let shows = items.filter { $0.kind == .series }.map(\.id)
            if !movies.isEmpty { try await api.deleteForCleanup(.radarr, ids: movies, exclude: exclude) }
            if !shows.isEmpty { try await api.deleteForCleanup(.sonarr, ids: shows, exclude: exclude) }
            picked = [:]
            await load()
        } catch {
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

/// When the disk fills at the pace of the samples: a least-squares line
/// through free space over time. Needs a week of history.
public enum DiskForecast: Equatable, Sendable {
    case unknown, steady
    case full(days: Double, perDay: Double)

    public static func compute(_ samples: [StatsSample]) -> DiskForecast {
        let points = samples.compactMap { s -> (Double, Double)? in
            guard let free = s.disk_free_bytes, free > 0 else { return nil }
            return (Double(s.ts) / 86_400, Double(free))
        }
        guard points.count >= 10, let first = points.first, let last = points.last, last.0 - first.0 >= 7 else { return .unknown }
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.0 } / n
        let my = points.reduce(0) { $0 + $1.1 } / n
        let sxy = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        let slope = sxx == 0 ? 0 : sxy / sxx
        guard slope < 0 else { return .steady }
        return .full(days: last.1 / -slope, perDay: -slope)
    }
}
