import ArrdeckData
import Foundation

/// Trakt's public lists — trending, most anticipated, popular — as search
/// results on the Add page, ported from the server's trakt.py. Trakt has no
/// artwork, so each title's poster comes from the arr's own lookup, kept a
/// day per title.
extension DirectBackend: TraktAPI {
    public func traktList(movies: Bool, list: TraktList) async throws -> [SearchResult] {
        try await call {
            let kind = movies ? "movie" : "series"
            let trakt = try registry.trakt()
            let rows = try await cached("trakt:\(kind):\(list.rawValue)", ttl: TraktLists.listTTL) {
                TraktLists.rows(try await TraktLists.fetch(trakt, kind: movies ? "movies" : "shows", which: list.rawValue), kind: kind)
            }
            let app = movies ? "radarr" : "sonarr"
            guard registry.isConfigured(app) else { return rows.map { Catalog.result($0, held: nil) } }
            let arr = try registry.arr(app)
            async let library = movies ? heldMovies(arr) : heldSeries(arr)
            let posters = await traktPosters(rows, kind: kind, arr: arr, lookup: movies ? "/movie/lookup" : "/series/lookup")
            let held = try await library
            return zip(rows, posters).map { row, poster in
                var row = row
                row.poster = poster
                return Catalog.result(row, held: held[row.remote_id])
            }
        }
    }

    /// One poster per row, in order. A found nothing is kept as "" so the
    /// title is not looked up again for a day; a failed lookup is not kept,
    /// so the next load tries again.
    private func traktPosters(_ rows: [SearchResult], kind: String, arr: KeyedClient, lookup: String) async -> [String?] {
        await boundedMap(rows.map(\.remote_id), width: lookupWidth) { remote in
            let poster = try? await self.cached("trakt:poster:\(kind):\(remote)", ttl: TraktLists.posterTTL) {
                let term = kind == "movie" ? "tmdb:\(remote)" : "tvdb:\(remote)"
                return TraktLists.lookupPoster(try await arr.get(lookup, query: ["term": term]).array) ?? ""
            }
            return poster.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

enum TraktLists {
    static let listTTL: TimeInterval = 3600
    static let posterTTL: TimeInterval = 86400

    /// `kind` movies or shows, `which` trending, anticipated or popular.
    /// Trending and anticipated wrap each title; popular does not.
    static func fetch(_ trakt: KeyedClient, kind: String, which: String) async throws -> [JSON] {
        let wrapper = kind == "movies" ? "movie" : "show"
        return try await trakt.get("/\(kind)/\(which)", query: ["limit": "20", "extended": "full"]).array.map { row in
            row[wrapper].object.isEmpty ? row : row[wrapper]
        }
    }

    /// Movies are keyed by TMDB id (Radarr's), shows by TVDB id (Sonarr's);
    /// a title without that id cannot be added, so it is left out.
    static func rows(_ items: [JSON], kind: String) -> [SearchResult] {
        let idField = kind == "movie" ? "tmdb" : "tvdb"
        return items.compactMap { item in
            let ids = item["ids"]
            guard let remote = ids[idField].int, remote != 0 else { return nil }
            return SearchResult(
                imdb_id: ids["imdb"].string, kind: kind, overview: item["overview"].string, remote_id: remote,
                title: item["title"].string ?? "", tmdb_id: ids["tmdb"].int, year: item["year"].nonZero
            )
        }
    }

    /// The first lookup result's poster: the CDN address Radarr hands out,
    /// else its images.
    static func lookupPoster(_ results: [JSON]) -> String? {
        let first = results.first ?? .null
        if let remote = first["remotePoster"].nonEmpty { return Artwork.normalise(remote) }
        return Artwork.poster(first["images"])
    }
}
