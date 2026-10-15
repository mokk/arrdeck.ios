import ArrdeckData
import Foundation

/// Plex beyond the dashboard: which episodes of a show were watched (for
/// spoiler protection, plex.py), play history as statistics and the plex.tv
/// watchlist (watchstats.py). Every image here is the arrs' or plex.tv's
/// public artwork; the server never put the Plex token in an image address,
/// and neither does this.
extension DirectBackend: WatchedEpisodesAPI, WatchingAPI {
    // MARK: - Watched episodes

    /// The watched episodes of one show, by the rating key the watched map
    /// gives. Plex away is no episode watched, as the server's empty block
    /// read: spoilers stay hidden rather than the screen failing.
    public func watchedEpisodes(key: String) async throws -> Set<String> {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw APIError.unexpectedStatus(422)
        }
        let block = await guarded("watched:episodes:\(key)") {
            try await cached("watched:episodes:\(key)", ttl: 300) {
                let episodes = try await registry.plex().get("/library/metadata/\(key)/allLeaves")
                return Self.watchedEpisodes(episodes["MediaContainer"]["Metadata"].array)
            }
        }
        return block.value ?? []
    }

    static func watchedEpisodes(_ episodes: [JSON]) -> Set<String> {
        Set(episodes.compactMap { episode in
            guard episode["viewCount"].truthy,
                  let season = episode["parentIndex"].int, let number = episode["index"].int
            else { return nil }
            return SpoilerGuard.key(season: season, episode: number)
        })
    }

    // MARK: - Watch statistics

    /// `days` 0 is all time. Plex's history has no durations, so hours are
    /// estimated from runtimes. Ten minutes per period and zone, and the last
    /// good answer while Plex is away.
    public func watchStats(days: Int, timeZone: String) async throws -> Block<WatchStats> {
        guard (0 ... 3650).contains(days) else { throw APIError.unexpectedStatus(422) }
        return await guarded("plex:stats:\(days):\(timeZone):block") {
            try await cached("plex:stats:\(days):\(timeZone)", ttl: 600) {
                let plex = try registry.plex()
                let since = days == 0 ? 0 : Int(Date.now.timeIntervalSince1970) - days * 86400
                async let history = plex.get("/status/sessions/history/all", query: [
                    "sort": "viewedAt:desc", "viewedAt>": "\(since)", "X-Plex-Container-Size": "20000",
                ], timeout: 30)
                async let titles = plexCatalogue(plex)
                async let accounts = plex.get("/accounts")
                async let movies = configuredList("radarr", "/movie")
                async let series = configuredList("sonarr", "/series")
                return WatchStatsBuilder.build(
                    history: try await history["MediaContainer"]["Metadata"].array,
                    titles: try await titles,
                    accounts: WatchStatsBuilder.accounts(try await accounts),
                    movies: WatchStatsBuilder.byGuid(try await movies, source: "tmdb", field: "tmdbId"),
                    series: WatchStatsBuilder.byGuid(try await series, source: "tvdb", field: "tvdbId"),
                    days: days, timeZone: timeZone
                )
            }
        }
    }

    /// Plex ratingKey → runtime and ids, for every movie and show. A show's
    /// runtime is its usual episode length, which is what a play of it
    /// costs. An hour: the library changes slower than the history.
    private func plexCatalogue(_ plex: KeyedClient) async throws -> [String: WatchStatsBuilder.Title] {
        try await cached("plex:catalogue", ttl: 3600) {
            let sections = try await plex.get("/library/sections")["MediaContainer"]["Directory"].array
                .filter { ["movie", "show"].contains($0["type"].string ?? "") }
            let contents = try await withThrowingTaskGroup(of: [JSON].self) { group in
                for section in sections {
                    let key = section["key"].string ?? section["key"].int.map(String.init) ?? ""
                    group.addTask {
                        try await plex.get("/library/sections/\(key)/all", query: ["includeGuids": "1"], timeout: 30)[
                            "MediaContainer"]["Metadata"].array
                    }
                }
                return try await group.reduce(into: []) { $0 += $1 }
            }
            var out: [String: WatchStatsBuilder.Title] = [:]
            for item in contents {
                guard let key = item["ratingKey"].string ?? item["ratingKey"].int.map(String.init), !key.isEmpty
                else { continue }
                out[key] = WatchStatsBuilder.Title(duration: item["duration"].int ?? 0, guids: Self.guidKeys(item))
            }
            return out
        }
    }

    /// An arr's whole list when it is set up, and nothing when it is not:
    /// the statistics and the watchlist just link less.
    private func configuredList(_ name: String, _ path: String) async throws -> [JSON] {
        guard registry.isConfigured(name) else { return [] }
        return try await registry.arr(name).get(path).array
    }

    // MARK: - Watchlist

    static let watchlistPage = 100
    static let watchlistPages = 10

    /// The token owner's plex.tv watchlist as search results, with what of it
    /// the arrs already have.
    public func plexWatchlist() async throws -> [SearchResult] {
        try await call {
            let plex = try registry.plex()
            async let items = cached("plex:watchlist", ttl: 300) { try await plexWatchlistItems(plex) }
            async let movies = configuredList("radarr", "/movie")
            async let series = configuredList("sonarr", "/series")
            return WatchStatsBuilder.watchlistRows(try await items, movies: try await movies, series: try await series)
        }
    }

    /// Not the server's library but plex.tv's, asked of Plex's discover
    /// service with the same token. Plex refuses pages over 100 or so; ten
    /// pages is plenty for a watchlist.
    private func plexWatchlistItems(_ server: KeyedClient) async throws -> [JSON] {
        let discover = KeyedClient(
            name: server.name, endpoint: Endpoint("https://discover.provider.plex.tv")!, prefix: "",
            auth: server.auth, http: server.http, unauthorized: "unauthorized (the watchlist needs a plex.tv token)"
        )
        var items: [JSON] = []
        for page in 0 ..< Self.watchlistPages {
            let container: JSON
            do {
                container = try await discover.get("/library/sections/watchlist/all", query: [
                    "includeGuids": "1",
                    "X-Plex-Container-Start": "\(page * Self.watchlistPage)",
                    "X-Plex-Container-Size": "\(Self.watchlistPage)",
                ], timeout: 30)["MediaContainer"]
            } catch let refused as ServiceRefused {
                throw ServiceUnavailable(server.name, "watchlist: HTTP \(refused.status)")
            }
            let batch = container["Metadata"].array
            items += batch
            if batch.count < Self.watchlistPage || items.count >= (container["totalSize"].int ?? 0) { break }
        }
        return items
    }
}

/// watchstats.py's `build_stats` and `watchlist_rows`: pure, so the counting
/// is tested on canned history.
enum WatchStatsBuilder {
    static let top = 10
    static let hourMS = 3_600_000.0

    struct Title: Sendable, Equatable {
        var duration: Int
        var guids: [String]
    }

    /// Plex's accounts by id. The owner is often nameless here; the stats
    /// fall back to "#id".
    static func accounts(_ payload: JSON) -> [Int: String] {
        var out: [Int: String] = [:]
        for account in payload["MediaContainer"]["Account"].array {
            if let id = account["id"].int { out[id] = account["name"].string ?? "" }
        }
        return out
    }

    /// An arr's titles keyed the way Plex's guids are: "tmdb:949".
    static func byGuid(_ items: [JSON], source: String, field: String) -> [String: JSON] {
        var out: [String: JSON] = [:]
        for item in items {
            let id = item[field]
            if let value = id.int, value != 0 {
                out["\(source):\(value)"] = item
            } else if let value = id.string, !value.isEmpty {
                out["\(source):\(value)"] = item
            }
        }
        return out
    }

    /// Python's `round(x, 1)`: the nearest tenth of the double as it is,
    /// ties to even — which is what printf's rounding does too.
    static func tenths(_ value: Double) -> Double {
        Double(String(format: "%.1f", value)) ?? value
    }

    static func hours(_ ms: Int) -> Double { tenths(Double(ms) / hourMS) }

    private struct Row {
        var title: String
        var plays = 0
        var ms = 0
        var guids: [String]
    }

    static func build(
        history: [JSON], titles: [String: Title], accounts: [Int: String], movies: [String: JSON],
        series: [String: JSON], days: Int, timeZone: String
    ) -> WatchStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone.isEmpty ? "UTC" : timeZone) ?? TimeZone(identifier: "UTC")!
        var weekday = [Int](repeating: 0, count: 7), hour = [Int](repeating: 0, count: 24)
        var users: [Int: (plays: Int, ms: Int)] = [:], userOrder: [Int] = []
        var shows: [String: Row] = [:], showOrder: [String] = []
        var films: [String: Row] = [:], filmOrder: [String] = []
        var moviePlays = 0, episodePlays = 0, totalMS = 0
        for play in history {
            let kind = play["type"].string
            guard kind == "movie" || kind == "episode" else { continue }
            let episode = kind == "episode"
            if episode { episodePlays += 1 } else { moviePlays += 1 }
            let path = Self.text(play[episode ? "grandparentKey" : "key"])
            let key = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let entry = titles[key]
            let ms = entry?.duration ?? 0
            totalMS += ms
            let account = play["accountID"].int ?? 0
            if users[account] == nil { userOrder.append(account) }
            users[account, default: (0, 0)].plays += 1
            users[account, default: (0, 0)].ms += ms
            if let viewed = play["viewedAt"].double, viewed != 0 {
                let local = calendar.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: viewed))
                // Monday first, as Python's weekday() counts
                weekday[((local.weekday ?? 2) + 5) % 7] += 1
                hour[local.hour ?? 0] += 1
            }
            let name = (play[episode ? "grandparentTitle" : "title"]).nonEmpty
            let rowKey = key.isEmpty ? (name ?? "") : key
            if episode {
                if shows[rowKey] == nil { showOrder.append(rowKey) }
                shows[rowKey, default: Row(title: name ?? "", guids: entry?.guids ?? [])].plays += 1
                shows[rowKey]!.ms += ms
            } else {
                if films[rowKey] == nil { filmOrder.append(rowKey) }
                films[rowKey, default: Row(title: name ?? "", guids: entry?.guids ?? [])].plays += 1
                films[rowKey]!.ms += ms
            }
        }

        func ranked(_ rows: [String: Row], _ order: [String]) -> [Row] {
            Array(DashboardPort.stableSorted(order.compactMap { rows[$0] }) {
                ($0.plays, $1.title) > ($1.plays, $0.title)
            }.prefix(top))
        }
        func link(_ row: Row, _ arr: [String: JSON], movie: Bool) -> WatchTitle {
            let match = row.guids.lazy.compactMap { arr[$0] }.first
            return WatchTitle(
                hours: hours(row.ms),
                movie_id: movie ? match?["id"].int : nil,
                plays: row.plays,
                poster: match.flatMap { Artwork.poster($0["images"]) },
                series_id: movie ? nil : match?["id"].int,
                title: row.title
            )
        }

        // busiest first; equal counts keep the order they were first seen in
        let people = DashboardPort.stableSorted(userOrder) { users[$0]!.plays > users[$1]!.plays }
        return WatchStats(
            by_hour: hour,
            by_weekday: weekday,
            days: days,
            episodes: episodePlays,
            hours: hours(totalMS),
            movies: moviePlays,
            plays: moviePlays + episodePlays,
            top_movies: ranked(films, filmOrder).map { link($0, movies, movie: true) },
            top_shows: ranked(shows, showOrder).map { link($0, series, movie: false) },
            users: people.map { id in
                .init(
                    hours: hours(users[id]!.ms), name: accounts[id].flatMap { $0.isEmpty ? nil : $0 } ?? "#\(id)",
                    plays: users[id]!.plays
                )
            }
        )
    }

    /// A key Plex may send as text or a number, as Python's `str(... or "")`.
    private static func text(_ value: JSON) -> String {
        value.string ?? value.int.map(String.init) ?? ""
    }

    /// Plex's ids for an item by source, the last one winning.
    static func ids(_ item: JSON) -> [String: String] {
        var out: [String: String] = [:]
        for guid in item["Guid"].array {
            guard let raw = guid["id"].string else { continue }
            let (source, value) = raw.range(of: "://").map { (String(raw[..<$0.lowerBound]), String(raw[$0.upperBound...])) }
                ?? (raw, "")
            if !value.isEmpty { out[source] = value }
        }
        return out
    }

    private static func digits(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    /// The watchlist as search results, so the add sheet takes it as is.
    /// What the arrs have is marked, with its id and whether it is done;
    /// what no arr could add is left out.
    static func watchlistRows(_ items: [JSON], movies: [JSON], series: [JSON]) -> [SearchResult] {
        var haveMovies: [Int: JSON] = [:], haveSeries: [Int: JSON] = [:]
        for movie in movies { if let id = movie["tmdbId"].int, id != 0 { haveMovies[id] = movie } }
        for show in series { if let id = show["tvdbId"].int, id != 0 { haveSeries[id] = show } }
        return items.compactMap { item in
            let kind = item["type"].string
            let ids = ids(item)
            let remote: Int, match: JSON?, done: Bool
            if kind == "movie", let tmdb = digits(ids["tmdb"]) {
                remote = tmdb
                match = haveMovies[tmdb]
                done = (match?["hasFile"] ?? .null).truthy
            } else if kind == "show", let tvdb = digits(ids["tvdb"]) {
                remote = tvdb
                match = haveSeries[tvdb]
                done = (match?["statistics"]["percentOfEpisodes"].double ?? 0) >= 100
            } else {
                return nil
            }
            let thumb = item["thumb"].string ?? ""
            return SearchResult(
                editions: [],
                has_file: match == nil ? nil : done,
                imdb_id: ids["imdb"],
                in_library: match != nil,
                kind: kind == "movie" ? "movie" : "series",
                library_id: match?["id"].int,
                monitored: match?["monitored"].bool,
                overview: item["summary"].string,
                poster: thumb.hasPrefix("https://") || thumb.hasPrefix("http://") ? Artwork.normalise(thumb) : nil,
                remote_id: remote,
                title: item["title"].string ?? "",
                tmdb_id: digits(ids["tmdb"]),
                year: item["year"].nonZero
            )
        }
    }
}
