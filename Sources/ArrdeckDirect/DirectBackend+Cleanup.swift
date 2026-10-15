import ArrdeckData
import Foundation

/// The cleanup assistant (the server's cleanup.py), removing some seasons of a
/// show, and Overseerr's open requests keyed for the library's badges
/// (requests.py). Nothing is deleted by the lists themselves; the screen sends
/// the chosen ids to the libraries' bulk delete. The cleanup *rules* are not
/// here: the server stores them.
extension DirectBackend: CleanupAPI, SeasonRemoveAPI, RequestsMapAPI {
    /// Four lists over the film and show libraries. One library down still
    /// lists the other; without Plex the two watch-based lists stay empty.
    public func cleanup(watchedDays: Int) async throws -> CleanupLists {
        async let movies = cleanupLibrary("radarr", "/movie")
        async let series = cleanupLibrary("sonarr", "/series")
        async let watched = cleanupWatched()
        return CleanupPort.build(
            movies: await movies, series: await series, watched: await watched,
            watchedDays: watchedDays, neverDays: CleanupPort.neverDays, now: Date.now.timeIntervalSince1970
        )
    }

    /// Removes the titles with their files; `exclude` keeps the arrs' import
    /// lists from adding them straight back. The library bulk delete, with
    /// the exclusion the cleanup screen asks for.
    public func deleteForCleanup(_ app: LibraryApp, ids: [Int], exclude: Bool) async throws {
        try await call {
            let editor = Bulk.editor(app)
            // Radarr names its exclusion flag differently from the other three
            let exclusion = app == .radarr ? "addImportExclusion" : "addImportListExclusion"
            try await registry.arr(app.arr.rawValue).send("DELETE", editor.path, json: [
                editor.ids: JSON(ids), "deleteFiles": true, exclusion: .bool(exclude),
            ], timeout: app == .lidarr ? 60 : nil)
            forgetLibrary(app, authors: false)
        }
    }

    /// Unmonitored first, so an RSS sync does not grab them straight back,
    /// then their files deleted.
    public func removeSeasons(series: Int, seasons: [Int]) async throws {
        try await call {
            // the server's request model wants at least one season
            guard !seasons.isEmpty else { throw APIError.unexpectedStatus(422) }
            let numbers = Set(seasons)
            let sonarr = try registry.arr("sonarr")
            var current = try await sonarr.get("/series/\(series)")
            if case let .array(all) = current["seasons"] {
                current = current.setting("seasons", .array(all.map { season in
                    season["seasonNumber"].int.map(numbers.contains) == true ? season.setting("monitored", false) : season
                }))
            }
            try await sonarr.send("PUT", "/series/\(series)", json: current)
            let files = try await sonarr.get("/episodefile", query: ["seriesId": String(series)]).array
                .filter { $0["seasonNumber"].int.map(numbers.contains) == true }
                .compactMap { $0["id"].int }
            if !files.isEmpty {
                try await sonarr.send("DELETE", "/episodefile/bulk", json: ["episodeFileIds": JSON(files)])
            }
            cache.remove(["library_map:series"])
        }
    }

    /// Open requests keyed for the library badges, a minute at a time, and
    /// the last good map while Overseerr is away. The server kept both under
    /// one key, which renewed the map's freshness on every read; the block
    /// has its own here, so the map does get re-read after a minute.
    public func requestMap() async throws -> [String: RequestState] {
        await guarded("requests:map:block") {
            try await cached("requests:map", ttl: 60) { try await RequestMapPort.load(registry.overseerr()) }
        }.value ?? [:]
    }

    private func cleanupLibrary(_ name: String, _ path: String) async -> [JSON] {
        guard registry.isConfigured(name), let client = try? registry.arr(name) else { return [] }
        return (try? await client.get(path).array) ?? []
    }

    /// Plex's watched map, shared with the watched screen under the
    /// server's key; nil when there is no Plex to ask, or it failed.
    private func cleanupWatched() async -> [String: WatchedItem]? {
        guard registry.isConfigured("plex") else { return nil }
        let map = try? await cached("watched", ttl: 600) { try await Self.loadWatched(registry.plex()) }
        return map.map { $0.items?.additionalProperties ?? [:] }
    }
}

/// cleanup.py's lists.
enum CleanupPort {
    static let largestLimit = 25
    static let neverDays = 365
    static let day: Double = 86_400

    static func build(
        movies: [JSON], series: [JSON], watched items: [String: WatchedItem]?, watchedDays: Int, neverDays: Int,
        now: TimeInterval
    ) -> CleanupLists {
        var rows: [(row: CleanupItem, entry: WatchedItem?)] = []
        for (kind, titles) in [(CleanupItem.kindPayload.movie, movies), (.series, series)] {
            for title in titles {
                let entry = items.flatMap { entry(kind: kind, title, $0) }
                guard let row = row(kind: kind, title, entry), (row.size ?? 0) > 0 else { continue }
                rows.append((row, entry))
            }
        }
        var watched: [CleanupItem] = [], never: [CleanupItem] = []
        if items != nil {
            for (row, entry) in rows {
                // Plex has never seen it: no basis to judge
                guard let entry else { continue }
                if entry.watched == true, let last = entry.last_viewed_at, last != 0,
                   now - Double(last) > Double(watchedDays) * day {
                    watched.append(row)
                }
                if (entry.progress ?? 0) == 0, let added = row.added?.timeIntervalSince1970,
                   now - added > Double(neverDays) * day {
                    never.append(row)
                }
            }
        }
        let all = rows.map(\.row)
        let bySize: (CleanupItem, CleanupItem) -> Bool = { ($0.size ?? 0) > ($1.size ?? 0) }
        return CleanupLists(
            largest: Array(DashboardPort.stableSorted(all, by: bySize).prefix(largestLimit)),
            never_watched: DashboardPort.stableSorted(never) {
                ($0.added?.timeIntervalSince1970 ?? 0) < ($1.added?.timeIntervalSince1970 ?? 0)
            },
            plex: items != nil,
            unmonitored: DashboardPort.stableSorted(all.filter { $0.monitored != true }, by: bySize),
            watched: DashboardPort.stableSorted(watched) { ($0.last_viewed_at ?? 0) < ($1.last_viewed_at ?? 0) }
        )
    }

    static func row(kind: CleanupItem.kindPayload, _ item: JSON, _ entry: WatchedItem?) -> CleanupItem? {
        guard let id = item["id"].int else { return nil }
        let size = kind == .movie ? item["sizeOnDisk"] : item["statistics"]["sizeOnDisk"]
        var row = CleanupItem(
            added: item["added"].date,
            id: id,
            kind: kind,
            last_viewed_at: entry?.last_viewed_at,
            monitored: item["monitored"].bool ?? false,
            poster: Artwork.poster(item["images"]),
            seasons: [],
            size: size.whole ?? 0,
            title: item["title"].string,
            year: item["year"].int
        )
        if kind == .series {
            // the seasons that have files, so some can go instead of all
            row.seasons = DashboardPort.stableSorted(
                item["seasons"].array.filter { $0["statistics"]["sizeOnDisk"].truthy }.map { season in
                    let stats = season["statistics"]
                    return .init(
                        files: stats["episodeFileCount"].int ?? 0, monitored: season["monitored"].bool ?? false,
                        number: season["seasonNumber"].int ?? 0, size: stats["sizeOnDisk"].whole ?? 0
                    )
                }
            ) { $0.number < $1.number }
        }
        return row
    }

    /// The title's Plex entry, by the ids the arr holds: a film by TMDB then
    /// IMDb, a show by TVDB first.
    static func entry(kind: CleanupItem.kindPayload, _ item: JSON, _ items: [String: WatchedItem]) -> WatchedItem? {
        let ids = kind == .movie
            ? ["tmdb:\(item["tmdbId"].printed)", "imdb:\(item["imdbId"].printed)"]
            : ["tvdb:\(item["tvdbId"].printed)", "tmdb:\(item["tmdbId"].printed)", "imdb:\(item["imdbId"].printed)"]
        return ids.lazy.compactMap { items[$0] }.first
    }
}

/// requests.py's map of open requests.
enum RequestMapPort {
    /// Waiting for approval, or approved and not yet on disk.
    static let openFilters = ["pending", "processing"]
    static let take = 100

    static func load(_ overseerr: KeyedClient) async throws -> [String: RequestState] {
        async let pending = page(overseerr, openFilters[0])
        async let processing = page(overseerr, openFilters[1])
        var out: [String: RequestState] = [:]
        for page in try await [pending, processing] {
            for request in page["results"].array {
                let state = RequestState(
                    request_id: request["id"].int ?? 0,
                    requested_by: request["requestedBy"]["displayName"].nonEmpty ?? "",
                    status: request["status"].int ?? 0
                )
                // the first request for a title is the one its badge shows
                for key in keys(request) where out[key] == nil { out[key] = state }
            }
        }
        return out
    }

    static func page(_ overseerr: KeyedClient, _ filter: String) async throws -> JSON {
        try await overseerr.get("/request", query: ["filter": filter, "take": String(take), "sort": "added"])
    }

    /// How a library card finds its request: films by TMDB id, shows by TVDB
    /// and TMDB id both, since a Sonarr row may carry either. The kind keeps
    /// a film and a show that share a TMDB number apart.
    static func keys(_ request: JSON) -> [String] {
        let media = request["media"]
        let kind = request["type"].nonEmpty ?? media["mediaType"].nonEmpty ?? "movie"
        var keys: [String] = []
        if media["tmdbId"].truthy { keys.append("\(kind):tmdb:\(media["tmdbId"].printed)") }
        if kind == "tv", media["tvdbId"].truthy { keys.append("tv:tvdb:\(media["tvdbId"].printed)") }
        return keys
    }
}
