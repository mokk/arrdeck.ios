import ArrdeckData
import Foundation

/// Finding and adding titles: the arrs' own lookups, Overseerr's popular
/// lists, Radarr's collections and raw Prowlarr releases. Ported from the
/// server's discover.py and releases.py; books are in
/// `Direct+CatalogBooks.swift`, music in `Direct+CatalogMusic.swift`, the
/// popular page in `Direct+CatalogPopular.swift`.
extension DirectBackend: DiscoverAPI {
    public func search(_ kind: MediaKind, query: String) async throws -> [SearchResult] {
        try await call {
            switch kind {
            case .movies:
                let radarr = try registry.arr("radarr")
                async let library = heldMovies(radarr)
                let found = try await radarr.get("/movie/lookup", query: ["term": query]).array
                let held = try await library
                return found.prefix(30).map { movie in
                    Catalog.result(Discovery.movie(movie), held: movie["tmdbId"].int.flatMap { held[$0] })
                }
            case .series:
                let sonarr = try registry.arr("sonarr")
                async let library = heldSeries(sonarr)
                let found = try await sonarr.get("/series/lookup", query: ["term": query]).array
                let held = try await library
                return found.prefix(30).map { series in
                    // no TMDB id here, as the server sent none
                    let result = SearchResult(
                        imdb_id: series["imdbId"].string, kind: "series", overview: series["overview"].string,
                        poster: Artwork.poster(series["images"]), remote_id: series["tvdbId"].int ?? 0,
                        title: series["title"].string ?? "", year: series["year"].int
                    )
                    return Catalog.result(result, held: series["tvdbId"].int.flatMap { held[$0] })
                }
            case .books:
                return try await catalogBookSearch(query)
            case .music:
                return try await catalogMusicSearch(query)
            }
        }
    }

    public func searchReleases(_ query: String) async throws -> [Release] {
        try await call {
            // every indexer at once: slow, so allowed long
            let found = try await registry.arr("prowlarr")
                .get("/search", query: ["query": query, "type": "search"], timeout: 90).array
            return found.prefix(100).map { release in
                Release(
                    age_days: release["ageMinutes"].double.map { $0 / 1440 }, download_url: release["downloadUrl"].string,
                    guid: release["guid"].string ?? "", indexer: release["indexer"].string,
                    indexer_id: release["indexerId"].int ?? 0, leechers: release["leechers"].int,
                    seeders: release["seeders"].int, size: release["size"].int, title: release["title"].string ?? ""
                )
            }
        }
    }

    public func discover(_ kind: MediaKind) async throws -> [SearchResult] {
        try await call {
            switch kind {
            case .movies:
                let overseerr = try registry.overseerr()
                let popular = try await cached("discover:movies:filtered", ttl: 600) {
                    try await Discovery.popular(overseerr, path: "/discover/movies")
                }
                let held = try await heldMovies(try registry.arr("radarr"))
                return popular.map { movie in
                    let result = SearchResult(
                        kind: "movie", overview: movie["overview"].string, poster: Catalog.tmdbPoster(movie["posterPath"].string),
                        remote_id: movie["id"].int ?? 0, title: movie["title"].string ?? "", tmdb_id: movie["id"].int,
                        year: movie["releaseDate"].year
                    )
                    return Catalog.result(result, held: movie["id"].int.flatMap { held[$0] })
                }
            case .series:
                let overseerr = try registry.overseerr()
                let shows = try await cached("discover:series:filtered", ttl: 600) {
                    let popular = try await Discovery.popular(overseerr, path: "/discover/tv")
                    return await withTvdbIDs(popular, overseerr)
                }
                let held = try await heldSeries(try registry.arr("sonarr"))
                return shows.map { Catalog.result($0, held: held[$0.remote_id]) }
            case .books, .music:
                return [] // Overseerr has no popular list for books or music
            }
        }
    }

    /// Sonarr adds by TVDB id, which Overseerr's popular list lacks: each
    /// show is looked up once and its details kept a day, so a list costs
    /// twenty calls once and then nothing. A show that fails to resolve is
    /// left out.
    private func withTvdbIDs(_ shows: [JSON], _ overseerr: KeyedClient) async -> [SearchResult] {
        await withTaskGroup(of: (Int, SearchResult?).self) { group in
            for (index, show) in shows.enumerated() {
                guard let tmdb = show["id"].int else { continue }
                group.addTask {
                    let details = try? await self.cached("tvdetails:\(tmdb)", ttl: 86400) {
                        try await overseerr.get("/tv/\(tmdb)")
                    }
                    guard let external = details?["externalIds"], let tvdb = external["tvdbId"].int, tvdb != 0 else {
                        return (index, nil)
                    }
                    return (index, SearchResult(
                        imdb_id: external["imdbId"].string, kind: "series", overview: show["overview"].string,
                        poster: Catalog.tmdbPoster(show["posterPath"].string), remote_id: tvdb,
                        title: show["name"].string ?? "", tmdb_id: tmdb, year: show["firstAirDate"].year
                    ))
                }
            }
            var resolved: [(Int, SearchResult)] = []
            for await case let (index, result?) in group { resolved.append((index, result)) }
            return resolved.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func grab(guid: String, indexerID: Int) async throws {
        try await call {
            _ = try await registry.arr("prowlarr").send("POST", "/search", json: ["guid": .string(guid), "indexerId": JSON(indexerID)])
        }
    }

    /// A new title with the arr's defaults otherwise: monitored, and searched
    /// for at once. A show monitors what Sonarr's own default says; an artist
    /// every album.
    public func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, edition: String?) async throws {
        try await call {
            switch result.searchKind {
            case .movie:
                try await registry.arr("radarr").send("POST", "/movie", json: [
                    "tmdbId": JSON(result.remote_id), "title": .string(result.title),
                    "qualityProfileId": JSON(qualityProfile), "rootFolderPath": .string(rootFolder), "monitored": true,
                    "addOptions": ["searchForMovie": true],
                ])
                forget("library_map:movie")
            case .series:
                try await registry.arr("sonarr").send("POST", "/series", json: [
                    "tvdbId": JSON(result.remote_id), "title": .string(result.title),
                    "qualityProfileId": JSON(qualityProfile), "rootFolderPath": .string(rootFolder), "monitored": true,
                    "seasonFolder": true, "addOptions": ["searchForMissingEpisodes": true],
                ])
                forget("library_map:series")
            case .book:
                try await catalogAddBook(
                    result, edition: edition ?? result.foreign_edition_id, qualityProfile: qualityProfile,
                    rootFolder: rootFolder, metadataProfile: metadataProfile
                )
            case .artist:
                try await catalogAddArtist(
                    result, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadataProfile,
                    monitor: "all"
                )
            case .album:
                try await catalogAddAlbum(
                    result, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadataProfile
                )
            case nil:
                throw APIError.unexpectedStatus(422)
            }
        }
    }

    // MARK: - Collections

    public func collections() async throws -> [Collection] {
        try await call {
            let radarr = try registry.arr("radarr")
            async let library = heldMovies(radarr)
            let all = try await radarr.get("/collection").array
            let held = try await library
            return all.compactMap { collection -> Collection? in
                guard let id = collection["id"].int else { return nil }
                let movies = collection["movies"].array
                return Collection(
                    id: id, missing_count: movies.filter { $0["tmdbId"].int.flatMap { held[$0] } == nil }.count,
                    monitored: collection["monitored"].bool ?? false, movie_count: movies.count,
                    poster: Artwork.poster(collection["images"]), title: collection["title"].string
                )
            }
            .sorted { ($0.title ?? "").lowercased() < ($1.title ?? "").lowercased() }
        }
    }

    public func collectionDetail(_ id: Int) async throws -> CollectionDetail {
        try await call {
            let radarr = try registry.arr("radarr")
            async let library = heldMovies(radarr)
            let full = try await radarr.collection(id)
            let held = try await library
            return CollectionDetail(
                id: id, monitored: full["monitored"].bool ?? false,
                movies: full["movies"].array.map { movie in
                    Catalog.result(Discovery.movie(movie), held: movie["tmdbId"].int.flatMap { held[$0] })
                },
                overview: full["overview"].string, poster: Artwork.poster(full["images"]), title: full["title"].string
            )
        }
    }

    /// Radarr takes the whole collection back, so it is read, changed and sent.
    public func setCollectionMonitored(_ id: Int, _ monitored: Bool) async throws {
        try await call {
            let radarr = try registry.arr("radarr")
            let full = try await radarr.collection(id)
            try await radarr.send("PUT", "/collection/\(id)", json: full.setting("monitored", .bool(monitored)))
        }
    }

    public func popular(hours: Int, limit: Int) async throws -> Block<PopularSnapshot> {
        await catalogPopular(hours: hours, limit: limit)
    }

    // MARK: - What the library holds

    /// Radarr's films by TMDB id, for the in-library badges and editing in
    /// place from the Add page. Kept a minute: every keystroke of a search asks.
    func heldMovies(_ radarr: KeyedClient) async throws -> [Int: Catalog.Held] {
        try await cached("library_map:movie", ttl: 60) {
            Discovery.held(try await radarr.get("/movie").array, id: "tmdbId") { $0["hasFile"].bool ?? false }
        }
    }

    /// Sonarr's shows by TVDB id. A show counts as downloaded once every
    /// episode is on disk.
    func heldSeries(_ sonarr: KeyedClient) async throws -> [Int: Catalog.Held] {
        try await cached("library_map:series", ttl: 60) {
            Discovery.held(try await sonarr.get("/series").array, id: "tvdbId") { series in
                let stats = series["statistics"]
                return (stats["episodeCount"].int ?? 0) > 0 && (stats["percentOfEpisodes"].double ?? 0) >= 100
            }
        }
    }
}

private extension KeyedClient {
    func collection(_ id: Int) async throws -> JSON {
        guard let full = try await get("/collection").array.first(where: { $0["id"].int == id }) else {
            throw APIError.refused("collection not found")
        }
        return full
    }
}

private enum Discovery {
    /// Languages kept from Overseerr's popular lists.
    static let westernLanguages: Set = ["en", "da", "sv", "no", "nb", "nn", "fi", "is"]
    /// Titles to aim for after filtering, and the pages that may take.
    static let target = 48
    static let maxPages = 8

    /// Popular titles across pages, western languages only, until there are
    /// enough or the pages run out. Rankings shift between page fetches, so a
    /// title can come twice.
    static func popular(_ overseerr: KeyedClient, path: String) async throws -> [JSON] {
        var out: [JSON] = []
        var seen: Set<Int> = []
        for page in 1 ... maxPages {
            let results = try await overseerr.get(path, query: ["page": String(page)])["results"].array
            if results.isEmpty { break }
            for result in results {
                let id = result["id"].int ?? 0
                guard !seen.contains(id), westernLanguages.contains(result["originalLanguage"].nonEmpty ?? "en")
                else { continue }
                seen.insert(id)
                out.append(result)
            }
            if out.count >= target { break }
        }
        return Array(out.prefix(target))
    }

    /// A Radarr film, from a lookup or a collection, as a search result.
    static func movie(_ movie: JSON) -> SearchResult {
        SearchResult(
            imdb_id: movie["imdbId"].string, kind: "movie", overview: movie["overview"].string,
            poster: Artwork.poster(movie["images"]), remote_id: movie["tmdbId"].int ?? 0,
            title: movie["title"].string ?? "", tmdb_id: movie["tmdbId"].int, year: movie["year"].int
        )
    }

    static func held(_ items: [JSON], id field: String, downloaded: (JSON) -> Bool) -> [Int: Catalog.Held] {
        var out: [Int: Catalog.Held] = [:]
        for item in items {
            guard let remote = item[field].int, remote != 0, let id = item["id"].int else { continue }
            out[remote] = Catalog.Held(
                libraryID: id, monitored: item["monitored"].bool ?? false,
                qualityProfile: item["qualityProfileId"].int, hasFile: downloaded(item)
            )
        }
        return out
    }
}
