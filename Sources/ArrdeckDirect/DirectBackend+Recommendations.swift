import ArrdeckData
import Foundation

/// Radarr's own suggestions from the library, "not interested", and sending
/// a held release on now. Ported from the server's discover.py
/// (`recommendations`, `dismiss_recommendation`) and arrqueue.py (`grab_now`).
extension DirectBackend: RecommendationsAPI, QueueGrabAPI {
    public func recommendations() async throws -> [SearchResult] {
        try await call { Recommendations.rows(try await radarrRecommendations(try registry.arr("radarr"))) }
    }

    /// A Radarr exclusion, so no list or suggestion brings the film back.
    /// The kept list is marked rather than dropped, so the next look leaves
    /// it out without asking Radarr again.
    public func dismissRecommendation(_ tmdbID: Int) async throws {
        try await call {
            let radarr = try registry.arr("radarr")
            let items = try await radarrRecommendations(radarr)
            let movie = items.first { $0["tmdbId"].int == tmdbID } ?? .null
            try await radarr.send("POST", "/exclusions", json: [
                "tmdbId": JSON(tmdbID), "movieTitle": .string(movie["title"].nonEmpty ?? String(tmdbID)),
                "movieYear": JSON(movie["year"].int ?? 0),
            ])
            cache.set(Recommendations.key, items.map { $0["tmdbId"].int == tmdbID ? $0.setting("isExcluded", true) : $0 })
        }
    }

    /// Past a delay profile's wait, to the download client now.
    public func grabNow(app: ArrApp, id: Int) async throws {
        try await call {
            _ = try await registry.arr(app.rawValue).send("POST", "/queue/grab/\(id)")
        }
    }

    /// Radarr's import-list view with only the recommendations asked for,
    /// kept an hour as it came: working them out takes Radarr a while.
    private func radarrRecommendations(_ radarr: KeyedClient) async throws -> [JSON] {
        try await cached(Recommendations.key, ttl: Recommendations.ttl) {
            try await radarr.get("/importlist/movie", query: [
                "includeRecommendations": "true", "includeTrending": "false", "includePopular": "false",
            ], timeout: 60).array
        }
    }
}

enum Recommendations {
    static let key = "radarr:recommendations"
    static let ttl: TimeInterval = 3600

    /// Radarr's suggestions minus what it already has or was told to skip,
    /// best known first.
    static func rows(_ items: [JSON]) -> [SearchResult] {
        items
            .filter { movie in
                movie["isRecommendation"].bool == true && movie["isExisting"].bool != true
                    && movie["isExcluded"].bool != true && (movie["tmdbId"].int ?? 0) != 0
            }
            .enumerated()
            // stable, as Python's sort is: equal popularity keeps Radarr's order
            .sorted { ($1.element["popularity"].double ?? 0, $0.offset) < ($0.element["popularity"].double ?? 0, $1.offset) }
            .map { _, movie in
                let tmdb = movie["tmdbId"].int ?? 0
                let result = SearchResult(
                    imdb_id: movie["imdbId"].string, kind: "movie", overview: movie["overview"].string,
                    poster: movie["remotePoster"].nonEmpty.map { Artwork.normalise($0) } ?? Artwork.poster(movie["images"]),
                    remote_id: tmdb, title: movie["title"].string ?? "", tmdb_id: tmdb,
                    year: movie["year"].nonZero
                )
                return Catalog.result(result, held: nil)
            }
    }
}
