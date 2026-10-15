import ArrdeckData
import Foundation

extension DirectBackend: ManageAPI {
    func probeStatus(_ name: String) async -> ServiceStatus {
        do {
            let version = try await registry.probeVersion(name)
            let update = Self.updateApps.contains(name) ? await pendingUpdate(name) : nil
            return ServiceStatus(
                ok: true, retries: registry.retries.count(name), service: name, update_available: update,
                version: version
            )
        } catch {
            return ServiceStatus(error: Self.reason(error), ok: false, retries: registry.retries.count(name), service: name)
        }
    }

    /// Only the arrs publish a release feed with installed and latest flags.
    private static let updateApps: Set = ["radarr", "sonarr", "readarr", "lidarr", "prowlarr"]

    /// The newest release the service knows of, when it is not the one
    /// running. Checked hourly, not per poll: the arrs look for updates
    /// themselves every six hours. A missing feed is no status failure.
    private func pendingUpdate(_ name: String) async -> String? {
        let pending = try? await cached("update:\(name)", ttl: 3600) { () async -> PendingUpdate in
            guard let rows = try? await registry.arr(name).get("/update").array,
                  let latest = rows.first(where: { $0["latest"].bool == true }), latest["installed"].bool != true
            else { return PendingUpdate(version: nil) }
            return PendingUpdate(version: latest["version"].string)
        }
        return pending?.version
    }

    // MARK: - Libraries

    public func libraryMovies() async throws -> [LibraryMovie] {
        try await call {
            let movies = try await registry.arr("radarr").get("/movie").array
            return Shelf.bySortTitle(movies).compactMap(Shelf.movie)
        }
    }

    public func librarySeries() async throws -> [LibrarySeries] {
        try await call {
            let sonarr = try registry.arr("sonarr")
            async let upcoming = nextEpisodes(sonarr)
            let series = try await sonarr.get("/series").array
            let next = await upcoming
            return Shelf.bySortTitle(series).compactMap { Shelf.series($0, next: next) }
        }
    }

    /// The first upcoming episode of every show, from one calendar call
    /// rather than an episode list per show. Cached: the calendar barely
    /// moves in minutes. "Up next" is decoration on the library, so a
    /// failure is no episodes rather than no library.
    private func nextEpisodes(_ sonarr: KeyedClient) async -> [Int: NextEpisode] {
        let found = try? await cached("sonarr:next_episodes", ttl: 900) {
            let now = Date.now
            let episodes = try await sonarr.get("/calendar", query: [
                "start": now.ISO8601Format(), "end": now.addingTimeInterval(Shelf.upNextDays * 86400).ISO8601Format(),
                "includeSeries": "true",
            ])
            return Shelf.nextEpisodes(episodes.array)
        }
        return found ?? [:]
    }

    public func libraryBooks() async throws -> [LibraryBook] {
        try await call {
            let readarr = try registry.arr("readarr")
            // Readarr's book rows do not embed the author, and the list needs one name per book
            async let authors = cached("readarr:authors", ttl: 60) {
                try await readarr.get("/author").array.reduce(into: [Int: JSON]()) { all, author in
                    if let id = author["id"].int { all[id] = author }
                }
            }
            let books = try await readarr.get("/book").array
            let byID = try await authors
            let rows = books.compactMap { Shelf.book($0, authors: byID) }
            // Adding an author lists their whole bibliography, unmonitored. The
            // library is what was asked for or is on disk.
            return rows.filter { $0.monitored == true || $0.has_file == true }
                .sorted { a, b in
                    let (authorA, authorB) = ((a.author ?? "").lowercased(), (b.author ?? "").lowercased())
                    return authorA != authorB ? authorA < authorB : (a.title ?? "").lowercased() < (b.title ?? "").lowercased()
                }
        }
    }

    public func tags(_ app: ArrApp) async throws -> [LibraryTag] {
        // the server's tag route knows these three; Readarr's tags are never asked for
        guard [.radarr, .sonarr, .lidarr].contains(app) else { throw APIError.refused("unknown app '\(app.rawValue)'") }
        return try await call {
            try await registry.arr(app.rawValue).get("/tag").array
                .sorted { ($0["label"].string ?? "") < ($1["label"].string ?? "") }
                .compactMap { tag in tag["id"].int.map { LibraryTag(id: $0, label: tag["label"].string ?? "") } }
        }
    }

    // MARK: - Indexers

    public func indexers() async throws -> [Indexer] {
        try await call {
            try await registry.arr("prowlarr").get("/indexer").array.compactMap { indexer in
                indexer["id"].int.map {
                    Indexer(
                        enable: indexer["enable"].bool ?? false, id: $0, name: indexer["name"].string,
                        privacy: indexer["privacy"].string, _protocol: indexer["protocol"].string
                    )
                }
            }
        }
    }

    /// Prowlarr takes the whole indexer back, so it is read, flipped and sent.
    public func toggleIndexer(_ id: Int, enable: Bool) async throws {
        try await call {
            let prowlarr = try registry.arr("prowlarr")
            let full = try await prowlarr.indexer(id)
            try await prowlarr.send("PUT", "/indexer/\(id)", json: full.setting("enable", .bool(enable)))
        }
    }

    public func testIndexer(_ id: Int) async throws {
        try await call {
            let prowlarr = try registry.arr("prowlarr")
            let full = try await prowlarr.indexer(id)
            // Prowlarr tries the live site; its own timeout is ~100 s
            try await prowlarr.send("POST", "/indexer/test", json: full, timeout: 120)
        }
    }

    // MARK: - System

    public func status() async throws -> [ServiceStatus] {
        // every configured service at once; a slow one costs its own timeout only
        await withTaskGroup(of: ServiceStatus.self) { group in
            for name in registry.configured where DirectServices.listed(name, configured: true) {
                group.addTask { await self.probeStatus(name) }
            }
            var all: [ServiceStatus] = []
            for await status in group { all.append(status) }
            let order = DirectServices.all
            return all
                .filter { Services.known.contains($0.service) }
                .sorted { (order.firstIndex(of: $0.service) ?? 0) < (order.firstIndex(of: $1.service) ?? 0) }
        }
    }

    /// Scheduled tasks across the arrs. One arr being down does not blank the
    /// others' tasks, so the block is healthy even when some are missing.
    public func tasks() async throws -> Block<[ScheduledTask]> {
        await guarded("tasks") {
            try await cached("tasks", ttl: 60) {
                let found = await eachTaskApp { client in try await client.get("/system/task").array }
                return CatalogSystem.tasks(found.map { ($0.app, $0.rows) })
            }
        }
    }

    /// The arrs' own backups, newest first.
    public func arrBackups() async throws -> Block<[ArrBackup]> {
        await guarded("arr-backups") {
            try await cached("arr:backups", ttl: 300) {
                let found = await eachTaskApp { client in try await client.get("/system/backup").array }
                return CatalogSystem.backups(found.map { ($0.app, base: $0.base, $0.rows) })
            }
        }
    }

    /// Radarr, Sonarr and Prowlarr asked at once, in that order, leaving out
    /// any that is not set up or does not answer.
    private func eachTaskApp(
        _ fetch: @escaping @Sendable (KeyedClient) async throws -> [JSON]
    ) async -> [(app: String, base: String, rows: [JSON])] {
        let found = await withTaskGroup(of: (String, String, [JSON])?.self) { group in
            for app in CatalogSystem.taskApps {
                guard let client = try? registry.arr(app) else { continue }
                group.addTask {
                    guard let rows = try? await fetch(client) else { return nil }
                    return (app, client.endpoint.base.absoluteString, rows)
                }
            }
            var all: [String: (String, [JSON])] = [:]
            for await case let (app, base, rows)? in group { all[app] = (base, rows) }
            return all
        }
        return CatalogSystem.taskApps.compactMap { app in found[app].map { (app, $0.0, $0.1) } }
    }

    /// The arrs' own logs, newest first, so a failed grab does not mean
    /// opening each arr. Prowlarr's failures are the least visible elsewhere.
    public func logs(_ app: String, level: String?) async throws -> [LogEntry] {
        guard ["radarr", "sonarr", "readarr", "lidarr", "prowlarr"].contains(app) else {
            throw APIError.refused("unknown app '\(app)'")
        }
        return try await call {
            var query: [String: String?] = ["page": "1", "pageSize": "50", "sortKey": "time", "sortDirection": "descending"]
            if let level, !level.isEmpty { query["level"] = level }
            return try await registry.arr(app).get("/log", query: query)["records"].array.map { record in
                LogEntry(
                    app: app, exception: record["exception"].string, level: record["level"].string ?? "",
                    logger: record["logger"].string ?? "", message: record["message"].string ?? "",
                    time: record["time"].string ?? ""
                )
            }
        }
    }

    /// Read-only: what a profile grabs and what it stops at, the rest of what
    /// the add sheet's profile picker only names.
    public func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles {
        guard app == .radarr || app == .sonarr else { throw APIError.refused("unknown app '\(app.rawValue)'") }
        return try await call {
            let client = try registry.arr(app.rawValue)
            return try await cached("quality_profiles:\(app.rawValue)", ttl: 300) {
                async let formats = try? client.get("/customformat").array
                async let definitions = try? client.get("/qualitydefinition").array
                let profiles = try await client.get("/qualityprofile").array
                return CatalogSystem.qualityProfiles(
                    profiles: profiles, formats: await formats ?? [], definitions: await definitions ?? []
                )
            }
        }
    }

    // MARK: - Connections

    public func serviceSettings() async throws -> [String: ServiceSettings] {
        DirectServices.all.reduce(into: [:]) { all, name in
            let connection = registry.connection(name)
            all[name] = ServiceSettings(
                api_key: connection.apiKey, configured: registry.isConfigured(name), password: connection.password,
                url: connection.url, username: connection.username
            )
        }
    }

    public func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool {
        guard DirectServices.all.contains(name) else { throw APIError.refused("unknown service \(name)") }
        try await call {
            try registry.save(name, ServiceConnection(url: url, apiKey: apiKey, username: username, password: password))
        }
        // what was cached may belong to the old connection
        cache.clear()
        return registry.isConfigured(name)
    }

    public func testService(_ name: String) async throws -> String {
        try await call { try await registry.probeVersion(name) }
    }
}

/// "Up to date" cached as a value: a bare nil would read as a miss and be
/// asked again on every status poll.
private struct PendingUpdate: Sendable {
    var version: String?
}

private extension KeyedClient {
    func indexer(_ id: Int) async throws -> JSON {
        guard let full = try await get("/indexer").array.first(where: { $0["id"].int == id }) else {
            throw APIError.refused("indexer not found")
        }
        return full
    }
}

/// The library tabs' rows, from the arrs' own records: ported from the
/// server's movies.py, series.py and books.py.
private enum Shelf {
    /// How far ahead "Up next" looks for a show's next episode.
    static let upNextDays: TimeInterval = 120

    /// The arr's own sort title, as the server listed them.
    static func bySortTitle(_ items: [JSON]) -> [JSON] {
        items.sorted { ($0["sortTitle"].string ?? "") < ($1["sortTitle"].string ?? "") }
    }

    static func movie(_ movie: JSON) -> LibraryMovie? {
        guard let id = movie["id"].int else { return nil }
        return LibraryMovie(
            added: movie["added"].date, genres: movie["genres"].array.compactMap(\.string),
            has_file: movie["hasFile"].bool ?? false, id: id, imdb_id: movie["imdbId"].string,
            monitored: movie["monitored"].bool ?? false, poster: Artwork.poster(movie["images"]),
            quality: movie["movieFile"]["quality"]["quality"]["name"].string,
            quality_profile_id: movie["qualityProfileId"].int, rating: Ratings.headline(movie["ratings"]),
            runtime: movie["runtime"].nonZero, size_on_disk: movie["sizeOnDisk"].int ?? 0,
            slug: movie["titleSlug"].string, tags: movie["tags"].array.compactMap(\.int), title: movie["title"].string,
            tmdb_id: movie["tmdbId"].int, year: movie["year"].int
        )
    }

    static func series(_ series: JSON, next: [Int: NextEpisode]) -> LibrarySeries? {
        guard let id = series["id"].int else { return nil }
        let stats = series["statistics"]
        return LibrarySeries(
            added: series["added"].date, current_season: currentSeason(series, next: next[id]),
            episode_count: stats["episodeCount"].int ?? 0, episode_file_count: stats["episodeFileCount"].int ?? 0,
            genres: series["genres"].array.compactMap(\.string), id: id, imdb_id: series["imdbId"].string,
            monitored: series["monitored"].bool ?? false, network: series["network"].string,
            next_airing: series["nextAiring"].date, next_episode: next[id], poster: Artwork.poster(series["images"]),
            previous_airing: series["previousAiring"].date, quality_profile_id: series["qualityProfileId"].int,
            rating: Ratings.headline(series["ratings"]), size_on_disk: stats["sizeOnDisk"].int ?? 0,
            slug: series["titleSlug"].string, status: series["status"].string,
            tags: series["tags"].array.compactMap(\.int), title: series["title"].string, tmdb_id: series["tmdbId"].int,
            tvdb_id: series["tvdbId"].int, year: series["year"].int
        )
    }

    /// The earliest dated episode of each show in a calendar.
    static func nextEpisodes(_ calendar: [JSON]) -> [Int: NextEpisode] {
        var out: [Int: NextEpisode] = [:]
        for episode in calendar.sorted(by: { ($0["airDateUtc"].string ?? "") < ($1["airDateUtc"].string ?? "") }) {
            guard let seriesID = episode["seriesId"].int, out[seriesID] == nil,
                  let aired = episode["airDateUtc"].nonEmpty
            else { continue }
            out[seriesID] = NextEpisode(
                air_date: JSON.parseDate(aired), episode: episode["episodeNumber"].int ?? 0,
                finale_type: episode["finaleType"].string, season: episode["seasonNumber"].int ?? 0,
                title: episode["title"].string
            )
        }
        return out
    }

    /// The season worth a progress bar: the one the next episode is in, else
    /// the latest real one (specials are season 0).
    static func currentSeason(_ series: JSON, next: NextEpisode?) -> SeasonProgress? {
        var seasons: [Int: JSON] = [:]
        for season in series["seasons"].array {
            if let number = season["seasonNumber"].int { seasons[number] = season }
        }
        guard let number = next.map(\.season) ?? seasons.keys.filter({ $0 != 0 }).max(),
              let season = seasons[number]
        else { return nil }
        let stats = season["statistics"]
        return SeasonProgress(
            have: stats["episodeFileCount"].int ?? 0, number: number, total: stats["totalEpisodeCount"].int ?? 0
        )
    }

    /// A book with its author's name and quality profile: Readarr keeps the
    /// profile on the author, not the book.
    static func book(_ book: JSON, authors: [Int: JSON]) -> LibraryBook? {
        guard let id = book["id"].int else { return nil }
        let author = book["authorId"].int.flatMap { authors[$0] } ?? .null
        let stats = book["statistics"]
        return LibraryBook(
            added: book["added"].date, author: author["authorName"].string, author_id: book["authorId"].int,
            foreign_book_id: book["foreignBookId"].string, genres: book["genres"].array.compactMap(\.string),
            has_file: (stats["bookFileCount"].int ?? 0) > 0, id: id, monitored: book["monitored"].bool ?? false,
            page_count: book["pageCount"].nonZero,
            // Readarr calls the poster a cover
            poster: Artwork.musicCover(book["images"]), quality_profile_id: author["qualityProfileId"].int,
            rating: book["ratings"]["value"].double.flatMap { $0 == 0 ? nil : $0 },
            series_title: book["seriesTitle"].nonEmpty, size_on_disk: stats["sizeOnDisk"].int ?? 0,
            slug: book["titleSlug"].string, title: book["title"].string, year: book["releaseDate"].year
        )
    }
}
