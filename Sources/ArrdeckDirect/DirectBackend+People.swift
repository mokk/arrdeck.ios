import ArrdeckData
import Foundation

/// People from a film's credits: their films in the library, and — when
/// Overseerr is there to ask — the ones not. Ported from the server's
/// people.py.
///
/// Radarr answers every credit of every film in one call, but keys them by
/// an internal metadata id its movie list does not carry. A film's own
/// credits do carry it, so the map from metadata id to movie id is built one
/// call per film. The server kept that map in its database; here it is kept
/// for as long as the app runs, so only films added since are asked about.
extension DirectBackend: PeopleAPI {
    public func person(_ tmdbID: Int) async throws -> Person {
        try await call {
            let index = try await personIndex(try registry.arr("radarr"))
            let entry = index.people[tmdbID]
            var info = JSON.null
            var elsewhere: [SearchResult] = []
            if registry.isConfigured("overseerr") {
                do {
                    let overseerr = try registry.overseerr()
                    let found = try await cached("person:\(tmdbID)", ttl: 86_400) {
                        async let details = overseerr.get("/person/\(tmdbID)")
                        async let credits = overseerr.get("/person/\(tmdbID)/combined_credits")
                        return try await People.Found(info: details, credits: credits)
                    }
                    info = found.info
                    let owned = Set(index.movies.values.compactMap { $0["tmdbId"].int })
                    elsewhere = People.elsewhere(found.credits, inLibrary: owned)
                } catch {
                    // the library half stands on its own
                    info = .null
                    elsewhere = []
                }
            }
            if entry == nil, info.object.isEmpty { throw APIError.unexpectedStatus(404) }
            let owned = (entry?.movies ?? []).map { movieID, role in
                let movie = index.movies[movieID] ?? .null
                return PersonMovie(
                    has_file: movie["hasFile"].bool ?? false, monitored: movie["monitored"].bool ?? false,
                    movie_id: movieID, poster: Artwork.poster(movie["images"]), role: role,
                    title: movie["title"].string, year: movie["year"].int
                )
            }
            .enumerated()
            // newest first, stable as Python's sort is
            .sorted { ($1.element.year ?? 0, $0.offset) < ($0.element.year ?? 0, $1.offset) }
            .map(\.element)
            return Person(
                elsewhere: elsewhere,
                image: info["profilePath"].nonEmpty.map {
                    Artwork.normalise(People.tmdbOriginal + $0, size: Artwork.headshotSize)
                },
                known_for: info["knownForDepartment"].string, name: info["name"].nonEmpty ?? entry?.name,
                owned: owned, tmdb_id: tmdbID
            )
        }
    }

    /// Everyone in the library's credits, and the films by id, kept an hour.
    private func personIndex(_ radarr: KeyedClient) async throws -> People.Index {
        try await cached("people:index", ttl: People.indexTTL) {
            async let movies = radarr.get("/movie").array
            async let credits = radarr.get("/credit", timeout: 60).array
            let all = try await movies
            let mapping = await metadataMap(radarr, movies: all)
            return People.Index(people: People.index(try await credits, mapping: mapping), movies: all.byID)
        }
    }

    /// Metadata id to movie id, asking Radarr only about films not yet
    /// mapped, four at a time. A film that fails is asked about next time.
    private func metadataMap(_ radarr: KeyedClient, movies: [JSON]) async -> [Int: Int] {
        var stored: [Int: Int] = cache.fresh(People.mapKey, ttl: .infinity) ?? [:]
        let known = Set(stored.values)
        let missing = movies.compactMap { $0["id"].int }.filter { !known.contains($0) }
        guard !missing.isEmpty else { return stored }
        await withTaskGroup(of: (Int, Int?).self) { group in
            func ask(_ movieID: Int) {
                group.addTask {
                    let rows = try? await radarr.get("/credit", query: ["movieId": "\(movieID)"]).array
                    return (movieID, rows?.lazy.compactMap { $0["movieMetadataId"].int }.first)
                }
            }
            var pending = missing[...]
            for _ in 0 ..< People.mapConcurrency {
                guard let next = pending.popFirst() else { break }
                ask(next)
            }
            for await (movieID, metadataID) in group {
                if let metadataID { stored[metadataID] = movieID }
                if let next = pending.popFirst() { ask(next) }
            }
        }
        cache.set(People.mapKey, stored)
        return stored
    }
}

enum People {
    static let mapKey = "radarr:metadata_map"
    static let mapConcurrency = 4
    static let indexTTL: TimeInterval = 3600
    static let elsewhereLimit = 40
    static let tmdbOriginal = "https://image.tmdb.org/t/p/original"

    struct Entry: Sendable {
        var name: String?
        /// Movie id and role, in the order the credits name them.
        var movies: [(Int, String?)]
    }

    struct Index: Sendable {
        var people: [Int: Entry]
        var movies: [Int: JSON]
    }

    /// Overseerr's person and their whole filmography, kept a day together.
    struct Found: Sendable {
        var info: JSON
        var credits: JSON
    }

    /// Person TMDB id to their name and films with their role there, a film
    /// once per person even when they both wrote and directed it.
    static func index(_ credits: [JSON], mapping: [Int: Int]) -> [Int: Entry] {
        var people: [Int: Entry] = [:]
        for credit in credits {
            guard let person = credit["personTmdbId"].int,
                  let movie = credit["movieMetadataId"].int.flatMap({ mapping[$0] })
            else { continue }
            var entry = people[person] ?? Entry(name: credit["personName"].string, movies: [])
            guard !entry.movies.contains(where: { $0.0 == movie }) else { continue }
            let role = credit["type"].string == "cast" ? credit["character"] : credit["job"]
            entry.movies.append((movie, role.nonEmpty))
            people[person] = entry
        }
        return people
    }

    /// The person's released films missing from the library, best known
    /// first. A film not out yet has nothing to download.
    static func elsewhere(_ credits: JSON, inLibrary: Set<Int>, today: String = todayISO()) -> [SearchResult] {
        let all = (credits["cast"].array + credits["crew"].array).enumerated()
            .sorted { ($1.element["popularity"].double ?? 0, $0.offset) < ($0.element["popularity"].double ?? 0, $1.offset) }
            .map(\.element)
        var seen: Set<Int> = []
        var rows: [SearchResult] = []
        for credit in all {
            guard credit["mediaType"].string == "movie", let tmdb = credit["id"].int, tmdb != 0, !seen.contains(tmdb),
                  !inLibrary.contains(tmdb), let released = credit["releaseDate"].nonEmpty,
                  String(released.prefix(10)) <= today
            else { continue }
            seen.insert(tmdb)
            let result = SearchResult(
                kind: "movie", overview: credit["overview"].string,
                poster: credit["posterPath"].nonEmpty.map { Artwork.normalise(tmdbOriginal + $0) },
                remote_id: tmdb, title: credit["title"].string ?? "", tmdb_id: tmdb, year: credit["releaseDate"].year
            )
            rows.append(Catalog.result(result, held: nil))
        }
        return Array(rows.prefix(elsewhereLimit))
    }

    /// Today as the server's `date.today()` wrote it: the device's own day.
    static func todayISO(_ now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
