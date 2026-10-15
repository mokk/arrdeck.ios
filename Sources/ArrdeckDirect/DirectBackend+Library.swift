import ArrdeckData
import Foundation

/// The detail pages and the edits made from them, ported from the server's
/// movies.py, series.py, credits.py, library.py and music.py. Readarr's
/// books and authors, Bazarr's subtitles and Plex's watched state are in
/// Direct+LibraryExtras.swift.
extension DirectBackend: LibraryAPI {
    public func movieDetail(_ id: Int) async throws -> MovieDetail {
        try await call {
            let radarr = try registry.arr("radarr")
            async let fetched = radarr.get("/movie/\(id)")
            // history is decoration: the page opens without it
            async let events = try? radarr.get("/history/movie", query: ["movieId": "\(id)"])
            let movie = try await fetched
            let history = await events?.array ?? []
            return Self.movieDetail(movie, history: history)
        }
    }

    fileprivate static func movieDetail(_ movie: JSON, history: [JSON]) -> MovieDetail {
        let file = movie["movieFile"]
        let fileOut: MovieFile? = file.object.isEmpty ? nil : MovieFile(
            quality: file["quality"]["quality"]["name"].string,
            release_group: file["releaseGroup"].string,
            resolution: file["mediaInfo"]["resolution"].string,
            size: file["size"].int ?? 0
        )
        return MovieDetail(
            fanart: Artwork.fanart(movie["images"]),
            file: fileOut,
            has_file: movie["hasFile"].bool ?? false,
            history: LibraryShapes.history(history),
            id: movie["id"].int ?? 0,
            imdb_id: movie["imdbId"].string,
            monitored: movie["monitored"].bool ?? false,
            overview: movie["overview"].string,
            path: movie["path"].string,
            poster: Artwork.poster(movie["images"]),
            quality_profile_id: movie["qualityProfileId"].int,
            ratings: LibraryShapes.ratings(movie["ratings"]),
            runtime: movie["runtime"].int,
            size_on_disk: movie["sizeOnDisk"].int ?? 0,
            status: movie["status"].string,
            title: movie["title"].string,
            tmdb_id: movie["tmdbId"].int,
            year: movie["year"].int
        )
    }

    /// Top-billed cast and the crew worth naming. Cached for a day apart from
    /// the detail: ~60 rows a film that almost never change.
    public func movieCredits(_ id: Int) async throws -> Credits {
        try await call {
            try await cached("credits:\(id)", ttl: 86_400) {
                CreditsShape.from(try await registry.arr("radarr").get("/credit", query: ["movieId": "\(id)"]).array)
            }
        }
    }

    public func seriesDetail(_ id: Int) async throws -> SeriesDetail {
        try await call {
            Self.seriesDetail(try await registry.arr("sonarr").get("/series/\(id)"))
        }
    }

    fileprivate static func seriesDetail(_ series: JSON) -> SeriesDetail {
        let stats = series["statistics"]
        let seasons = series["seasons"].array.map { season in
            let stats = season["statistics"]
            return Season(
                episode_count: stats["episodeCount"].int ?? 0,
                episode_file_count: stats["episodeFileCount"].int ?? 0,
                monitored: season["monitored"].bool ?? false,
                number: season["seasonNumber"].int ?? 0,
                size_on_disk: stats["sizeOnDisk"].int ?? 0
            )
        }
        return SeriesDetail(
            air_time: series["airTime"].string,
            certification: series["certification"].string,
            episode_count: stats["episodeCount"].int ?? 0,
            episode_file_count: stats["episodeFileCount"].int ?? 0,
            fanart: Artwork.fanart(series["images"]),
            genres: series["genres"].array.compactMap(\.string),
            id: series["id"].int ?? 0,
            imdb_id: series["imdbId"].string,
            monitored: series["monitored"].bool ?? false,
            network: series["network"].string,
            overview: series["overview"].string,
            path: series["path"].string,
            poster: Artwork.poster(series["images"]),
            quality_profile_id: series["qualityProfileId"].int,
            ratings: LibraryShapes.ratings(series["ratings"]),
            runtime: series["runtime"].int,
            season_count: stats["seasonCount"].int ?? 0,
            seasons: seasons.sorted { $0.number < $1.number },
            size_on_disk: stats["sizeOnDisk"].int ?? 0,
            status: series["status"].string,
            title: series["title"].string,
            tmdb_id: series["tmdbId"].int,
            total_episode_count: stats["totalEpisodeCount"].int ?? 0,
            tvdb_id: series["tvdbId"].int,
            year: series["year"].int
        )
    }

    /// One season's episodes. includeEpisodeFile brings each file's quality,
    /// size and id (what Delete file needs) in the same call.
    public func episodes(series: Int, season: Int) async throws -> [Episode] {
        try await call {
            let all = try await registry.arr("sonarr").get(
                "/episode", query: ["seriesId": "\(series)", "includeEpisodeFile": "true"]
            )
            return all.array.filter { $0["seasonNumber"].int == season }.map(Self.episode)
                .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        }
    }

    fileprivate static func episode(_ episode: JSON) -> Episode {
        let file = episode["episodeFile"]
        return Episode(
            air_date: episode["airDateUtc"].string,
            episode: episode["episodeNumber"].int ?? 0,
            file_id: LibraryShapes.nonZero(file["id"].int) ?? LibraryShapes.nonZero(episode["episodeFileId"].int),
            finale_type: episode["finaleType"].string,
            has_file: episode["hasFile"].bool ?? false,
            id: episode["id"].int ?? 0,
            monitored: episode["monitored"].bool ?? false,
            overview: LibraryShapes.nonEmpty(episode["overview"].string),
            quality: file["quality"]["quality"]["name"].string,
            season: episode["seasonNumber"].int ?? 0,
            size: file["size"].int,
            title: episode["title"].string
        )
    }

    /// Quality profiles and root folders for the edit and add sheets, plus
    /// the metadata profiles Readarr and Lidarr match against. Five minutes:
    /// these change when someone edits the arr's settings.
    public func options(_ app: ArrApp) async throws -> Options {
        try await call {
            try await cached("options:\(app.rawValue)", ttl: 300) {
                let arr = try registry.arr(app.rawValue)
                async let profiles = arr.get("/qualityprofile")
                async let folders = arr.get("/rootfolder")
                var metadata: [QualityProfile]?
                if app == .readarr || app == .lidarr {
                    metadata = try await arr.get("/metadataprofile").array.compactMap(Self.profile)
                }
                return Options(
                    metadata_profiles: metadata,
                    quality_profiles: try await profiles.array.compactMap(Self.profile),
                    root_folders: try await folders.array.compactMap { folder in
                        guard let id = folder["id"].int else { return nil }
                        return RootFolder(free_space: folder["freeSpace"].int, id: id, path: folder["path"].string ?? "")
                    }
                )
            }
        }
    }

    private static func profile(_ json: JSON) -> QualityProfile? {
        json["id"].int.map { QualityProfile(id: $0, name: json["name"].string ?? "") }
    }

    public func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws {
        try await call {
            switch ref {
            case let .movie(id):
                try await putBack(registry.arr("radarr"), "/movie/\(id)", monitored: monitored, qualityProfile: qualityProfile)
                LibraryShapes.forget("library_map:movie", in: cache)
            case let .series(id):
                try await putBack(registry.arr("sonarr"), "/series/\(id)", monitored: monitored, qualityProfile: qualityProfile)
                LibraryShapes.forget("library_map:series", in: cache)
            case let .book(id):
                try await updateReadarrBook(id, monitored: monitored, qualityProfile: qualityProfile)
            case let .artist(id):
                // Lidarr takes the whole artist back; files stay where they are
                try await putBack(registry.arr("lidarr"), "/artist/\(id)", monitored: monitored,
                                  qualityProfile: qualityProfile, query: ["moveFiles": "false"], timeout: 30)
                LibraryShapes.forget("lidarr:artists", in: cache)
            case let .album(id):
                // an album's quality is its artist's; only the flag is its own,
                // and Lidarr's toggle sets it without the whole release list
                guard let monitored else { return }
                try await registry.arr("lidarr").send(
                    "PUT", "/album/monitor", json: ["albumIds": JSON([id]), "monitored": .bool(monitored)]
                )
                LibraryShapes.forget("lidarr:artists", in: cache)
            }
        }
    }

    /// Reads a title, changes what was asked and sends it all back: the arrs'
    /// PUT replaces the whole resource.
    private func putBack(
        _ arr: KeyedClient, _ path: String, monitored: Bool?, qualityProfile: Int?,
        query: [String: String?] = [:], timeout: TimeInterval? = nil
    ) async throws {
        var item = try await arr.get(path)
        if let monitored { item = item.setting("monitored", .bool(monitored)) }
        if let qualityProfile { item = item.setting("qualityProfileId", JSON(qualityProfile)) }
        try await arr.send("PUT", path, query: query, json: item, timeout: timeout)
    }

    public func delete(_ ref: MediaRef, deleteFiles: Bool) async throws {
        try await call {
            let files = deleteFiles ? "true" : "false"
            switch ref {
            case let .movie(id):
                try await registry.arr("radarr").send(
                    "DELETE", "/movie/\(id)", query: ["deleteFiles": files, "addImportExclusion": "false"]
                )
                LibraryShapes.forget("library_map:movie", in: cache)
            case let .series(id):
                try await registry.arr("sonarr").send("DELETE", "/series/\(id)", query: ["deleteFiles": files])
                LibraryShapes.forget("library_map:series", in: cache)
            case let .book(id):
                try await registry.arr("readarr").send(
                    "DELETE", "/book/\(id)", query: ["deleteFiles": files, "addImportListExclusion": "false"]
                )
            case let .artist(id):
                try await registry.arr("lidarr").send(
                    "DELETE", "/artist/\(id)", query: ["deleteFiles": files, "addImportListExclusion": "false"],
                    timeout: 60
                )
                LibraryShapes.forget("lidarr:artists", in: cache)
            case .album:
                // as LiveAPI: Lidarr removes albums with their artist; an
                // album's files go through MusicLibraryAPI.deleteAlbumFiles
                throw APIError.unexpectedStatus(405)
            }
        }
    }

    /// The arr's own search for a title. A Lidarr id is an album, which is
    /// what Wanted and the calendar carry; an artist is searched the way the
    /// bulk action does it, every monitored album of theirs.
    public func triggerSearch(_ ref: MediaRef) async throws {
        try await call {
            let (app, command): (String, JSON) = switch ref {
            case let .movie(id): ("radarr", ["name": "MoviesSearch", "movieIds": JSON([id])])
            case let .series(id): ("sonarr", ["name": "SeriesSearch", "seriesId": JSON(id)])
            case let .book(id): ("readarr", ["name": "BookSearch", "bookIds": JSON([id])])
            case let .album(id): ("lidarr", ["name": "AlbumSearch", "albumIds": JSON([id])])
            case let .artist(id): ("lidarr", ["name": "ArtistSearch", "artistId": JSON(id)])
            }
            try await registry.arr(app).send("POST", "/command", json: command)
        }
    }

    public func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {
        try await call {
            let sonarr = try registry.arr("sonarr")
            let current = try await sonarr.get("/series/\(series)")
            var seasons = current["seasons"].array
            guard let index = seasons.firstIndex(where: { $0["seasonNumber"].int == season }) else {
                // the server's 404 "season not found"
                throw APIError.unexpectedStatus(404)
            }
            seasons[index] = seasons[index].setting("monitored", .bool(monitored))
            try await sonarr.send("PUT", "/series/\(series)", json: current.setting("seasons", .array(seasons)))
        }
    }

    public func searchSeason(series: Int, season: Int) async throws {
        try await call {
            _ = try await registry.arr("sonarr").send(
                "POST", "/command", json: ["name": "SeasonSearch", "seriesId": JSON(series), "seasonNumber": JSON(season)]
            )
        }
    }

    /// Drops one episode's file so a search can replace it; the episode and
    /// its monitoring stay.
    public func deleteEpisodeFile(_ fileID: Int) async throws {
        try await call {
            try await registry.arr("sonarr").send("DELETE", "/episodefile/\(fileID)")
            LibraryShapes.forget("library_map:series", in: cache)
        }
    }

    public func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {
        try await call {
            _ = try await registry.arr("sonarr").send(
                "PUT", "/episode/monitor", json: ["episodeIds": JSON(ids), "monitored": .bool(monitored)]
            )
        }
    }

    public func searchEpisodes(_ ids: [Int]) async throws {
        try await call {
            _ = try await registry.arr("sonarr").send("POST", "/command", json: ["name": "EpisodeSearch", "episodeIds": JSON(ids)])
        }
    }
}

private enum CreditsShape {
    /// Crew is 30 rows deep and includes Thanks, Painter and Stunt Double;
    /// these are the jobs someone looks for on a film's page, Director first.
    static let crewJobs = ["Director", "Screenplay", "Writer", "Story", "Original Music Composer"]
    static let castLimit = 12
    static let crewLimit = 6
    /// A blockbuster can carry four Screenplay credits plus a Story credit,
    /// which would push the director out of view.
    static let crewPerJob = 2

    static func from(_ rows: [JSON]) -> Credits {
        func person(_ row: JSON, role: String) -> CreditPerson {
            let headshot = row["images"].array.first { $0["remoteUrl"].string != nil }
                .flatMap { $0["remoteUrl"].string ?? $0["url"].string }
            return CreditPerson(
                image: headshot.map { Artwork.normalise($0, size: Artwork.headshotSize) },
                name: row["personName"].string ?? "",
                role: LibraryShapes.nonEmpty(row[role].string),
                tmdb_id: row["personTmdbId"].int
            )
        }
        // `order` is TMDB's billing, which is what makes "top billed" mean
        // anything; the arr returns cast unsorted
        let cast = rows.filter { $0["type"].string == "cast" }.enumerated()
            .sorted { ($0.element["order"].int ?? 999, $0.offset) < ($1.element["order"].int ?? 999, $1.offset) }
            .map(\.element)
        let crewRows = rows.filter { crewJobs.contains($0["job"].string ?? "") && $0["type"].string == "crew" }
            .enumerated()
            .sorted { (crewJobs.firstIndex(of: $0.element["job"].string ?? "") ?? 0, $0.offset)
                < (crewJobs.firstIndex(of: $1.element["job"].string ?? "") ?? 0, $1.offset) }
            .map(\.element)
        // One person often holds two of these (Screenplay and Story); jobs are
        // in priority order, so the first mention is the one kept.
        var seen: Set<String> = []
        var perJob: [String: Int] = [:]
        var crew: [JSON] = []
        for row in crewRows {
            let name = row["personName"].string ?? "", job = row["job"].string ?? ""
            if seen.contains(name) || perJob[job, default: 0] >= crewPerJob { continue }
            seen.insert(name)
            perJob[job, default: 0] += 1
            crew.append(row)
        }
        return Credits(
            cast: cast.prefix(castLimit).map { person($0, role: "character") },
            crew: crew.prefix(crewLimit).map { person($0, role: "job") }
        )
    }
}

extension LibraryShapes {
    /// What the server's `cache.set(key, None)` did: the next read of `key`
    /// fetches afresh. The cache has no removal of its own, so a placeholder
    /// no reader asks for takes the entry's place.
    static func forget(_ keys: String..., in cache: BlockCache) {
        for key in keys { cache.set(key, Forgotten()) }
    }

    private struct Forgotten: Sendable {}
}
