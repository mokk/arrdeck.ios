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
    func deleteForCleanup(_ app: LibraryApp, ids: [Int], exclude: Bool) async throws
}

/// Some seasons of a show instead of all of it: unmonitored, then their files deleted.
public protocol SeasonRemoveAPI: Sendable {
    func removeSeasons(series: Int, seasons: [Int]) async throws
}

/// Open Overseerr requests keyed for the library: "movie:tmdb:1", "tv:tvdb:2".
public protocol RequestsMapAPI: Sendable {
    func requestMap() async throws -> [String: RequestState]
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
    /// Shows losing only some seasons; absent means the whole show goes.
    public private(set) var seasonPicks: [String: Set<Int>] = [:]
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

    /// The seasons that go with a show: all of them until some are kept.
    public func seasons(of item: CleanupItem) -> Set<Int> {
        seasonPicks[item.key] ?? Set((item.seasons ?? []).map(\.number))
    }

    /// Whether only some of this show's seasons go.
    public func isPartial(_ item: CleanupItem) -> Bool {
        let all = item.seasons ?? []
        return item.kind == .series && all.count > 1 && seasons(of: item).count < all.count
    }

    /// What deleting this frees: the chosen seasons, or the whole title.
    public func size(of item: CleanupItem) -> Int {
        guard isPartial(item) else { return item.size ?? 0 }
        let going = seasons(of: item)
        return (item.seasons ?? []).filter { going.contains($0.number) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var reclaim: Int { chosen.reduce(0) { $0 + size(of: $1) } }
    public var partials: [CleanupItem] { chosen.filter(isPartial).sorted { ($0.title ?? "") < ($1.title ?? "") } }

    public func toggle(_ item: CleanupItem) {
        if picked[item.key] == nil { picked[item.key] = item } else { picked[item.key] = nil }
        seasonPicks[item.key] = nil
    }

    /// Keeping or dropping one season; keeping the last one unticks the show.
    public func toggleSeason(_ item: CleanupItem, _ number: Int) {
        var going = seasons(of: item)
        if going.contains(number) { going.remove(number) } else { going.insert(number) }
        if going.isEmpty {
            picked[item.key] = nil
            seasonPicks[item.key] = nil
        } else {
            seasonPicks[item.key] = going
        }
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
            let partial = (api as? any SeasonRemoveAPI).map { remover in (remover, items.filter(isPartial)) }
            let partialIDs = Set(partial?.1.map(\.id) ?? [])
            let movies = items.filter { $0.kind == .movie }.map(\.id)
            let shows = items.filter { $0.kind == .series && !partialIDs.contains($0.id) }.map(\.id)
            if let (remover, shows) = partial {
                for show in shows { try await remover.removeSeasons(series: show.id, seasons: seasons(of: show).sorted()) }
            }
            if !movies.isEmpty { try await api.deleteForCleanup(.radarr, ids: movies, exclude: exclude) }
            if !shows.isEmpty { try await api.deleteForCleanup(.sonarr, ids: shows, exclude: exclude) }
            picked = [:]
            seasonPicks = [:]
            await load()
        } catch {
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}
