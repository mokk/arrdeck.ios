import ArrdeckAPI
import Foundation

public typealias MovieDetail = Components.Schemas.MovieDetailOut
public typealias MovieFile = Components.Schemas.MovieFileOut
public typealias SeriesDetail = Components.Schemas.SeriesDetailOut
public typealias Season = Components.Schemas.SeasonOut
public typealias Episode = Components.Schemas.EpisodeOut
public typealias Credits = Components.Schemas.CreditsOut
public typealias CreditPerson = Components.Schemas.CreditPersonOut
public typealias Options = Components.Schemas.OptionsOut
public typealias QualityProfile = Components.Schemas.QualityProfileOut
public typealias WatchedMap = Components.Schemas.WatchedMapOut
public typealias WatchedItem = Components.Schemas.WatchedItemOut

extension Components.Schemas.ServiceBlock_WatchedMapOut_: ServiceBlockShape {}

/// A title in one of the arrs' libraries — what a poster, a history row or a
/// queue item links to.
public enum MediaRef: Hashable, Sendable {
    case movie(Int)
    case series(Int)
    case book(Int)

    public init?(app: String, id: Int?) {
        guard let id else { return nil }
        switch app {
        case "radarr": self = .movie(id)
        case "sonarr": self = .series(id)
        case "readarr": self = .book(id)
        default: return nil
        }
    }

    public var app: ArrApp {
        switch self {
        case .movie: .radarr
        case .series: .sonarr
        case .book: .readarr
        }
    }

    public var id: Int {
        switch self {
        case let .movie(id), let .series(id), let .book(id): id
        }
    }
}

public typealias BookDetail = Components.Schemas.BookDetailOut
public typealias BookEdition = Components.Schemas.BookEditionOut

extension RecentItem {
    public var ref: MediaRef? { MediaRef(app: app.rawValue, id: library_id) }
}

extension HistoryItem {
    public var ref: MediaRef? {
        if let movie_id { return .movie(movie_id) }
        if let series_id { return .series(series_id) }
        if let book_id { return .book(book_id) }
        return nil
    }
}

/// Plex's view of a title, plus the deep link. Plex indexes watched state
/// under every external id it knows; each id the arr holds is tried until one
/// hits. nil means Plex has never seen the title.
public struct Watched: Equatable, Sendable {
    public var watched: Bool
    public var progress: Double
    public var url: URL?

    public init(watched: Bool, progress: Double, url: URL?) {
        self.watched = watched
        self.progress = progress
        self.url = url
    }

    public static func lookup(
        _ map: WatchedMap?, tmdb: Int? = nil, tvdb: Int? = nil, imdb: String? = nil
    ) -> Watched? {
        guard let items = map?.items?.additionalProperties else { return nil }
        let keys = [
            tmdb.map { "tmdb:\($0)" }, tvdb.map { "tvdb:\($0)" }, imdb.map { "imdb:\($0)" },
        ].compactMap { $0 }
        for key in keys {
            guard let item = items[key] else { continue }
            // The Plex link is composed here rather than shipped per entry:
            // every one shared the same server prefix, two thirds of the payload.
            let url: URL? = if let base = map?.base_url, let key = item.key { URL(string: base + key) } else { nil }
            return Watched(watched: item.watched ?? false, progress: item.progress ?? 0, url: url)
        }
        return nil
    }
}

public struct ExternalLink: Hashable, Sendable {
    public var label: String
    public var url: URL

    public static func links(for movie: MovieDetail, watched: Watched?) -> [ExternalLink] {
        var links: [ExternalLink] = []
        if let url = watched?.url { links.append(.init(label: "Plex", url: url)) }
        if let imdb = movie.imdb_id, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
            links.append(.init(label: "IMDb", url: url))
        }
        if let tmdb = movie.tmdb_id, let url = URL(string: "https://www.themoviedb.org/movie/\(tmdb)") {
            links.append(.init(label: "TMDB", url: url))
        }
        return links
    }

    public static func links(for book: BookDetail) -> [ExternalLink] {
        guard let goodreads = book.goodreads_url, let url = URL(string: goodreads) else { return [] }
        return [.init(label: "Goodreads", url: url)]
    }

    public static func links(for series: SeriesDetail, watched: Watched?) -> [ExternalLink] {
        var links: [ExternalLink] = []
        if let url = watched?.url { links.append(.init(label: "Plex", url: url)) }
        if let imdb = series.imdb_id, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
            links.append(.init(label: "IMDb", url: url))
        }
        if let tvdb = series.tvdb_id, let url = URL(string: "https://www.thetvdb.com/dereferrer/series/\(tvdb)") {
            links.append(.init(label: "TVDB", url: url))
        }
        if let tmdb = series.tmdb_id, let url = URL(string: "https://www.themoviedb.org/tv/\(tmdb)") {
            links.append(.init(label: "TMDB", url: url))
        }
        return links
    }
}

/// What the detail screens ask of the backend.
public protocol LibraryAPI: Sendable {
    func movieDetail(_ id: Int) async throws -> MovieDetail
    func movieCredits(_ id: Int) async throws -> Credits
    func seriesDetail(_ id: Int) async throws -> SeriesDetail
    func bookDetail(_ id: Int) async throws -> BookDetail
    func episodes(series: Int, season: Int) async throws -> [Episode]
    func options(_ app: ArrApp) async throws -> Options
    func watched() async throws -> Block<WatchedMap>
    func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws
    func delete(_ ref: MediaRef, deleteFiles: Bool) async throws
    func triggerSearch(_ ref: MediaRef) async throws
    func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws
    func searchSeason(series: Int, season: Int) async throws
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws
    func searchEpisodes(_ ids: [Int]) async throws
}

extension LiveAPI: LibraryAPI {
    public func movieDetail(_ id: Int) async throws -> MovieDetail {
        try await call {
            switch try await client.movie_detail_api_v1_library_movies__movie_id__detail_get(path: .init(movie_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func movieCredits(_ id: Int) async throws -> Credits {
        try await call {
            switch try await client.movie_credits_api_v1_library_movies__movie_id__credits_get(path: .init(movie_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func seriesDetail(_ id: Int) async throws -> SeriesDetail {
        try await call {
            switch try await client.series_detail_api_v1_library_series__series_id__detail_get(path: .init(series_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func bookDetail(_ id: Int) async throws -> BookDetail {
        try await call {
            switch try await client.book_detail_api_v1_library_books__book_id__detail_get(path: .init(book_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func episodes(series: Int, season: Int) async throws -> [Episode] {
        try await call {
            switch try await client.series_episodes_api_v1_library_series__series_id__episodes_get(
                path: .init(series_id: series), query: .init(season: season)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func options(_ app: ArrApp) async throws -> Options {
        try await call {
            switch try await client.options_api_v1_options__app__get(path: .init(app: app.rawValue)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func watched() async throws -> Block<WatchedMap> {
        try await call {
            switch try await client.watched_api_v1_watched_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws {
        try await call {
            let body = Components.Schemas.LibraryUpdateIn(monitored: monitored, quality_profile_id: qualityProfile)
            switch ref {
            case let .movie(id):
                switch try await client.update_movie_api_v1_library_movies__movie_id__patch(path: .init(movie_id: id), body: .json(body)) {
                case .ok: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .series(id):
                switch try await client.update_series_api_v1_library_series__series_id__patch(path: .init(series_id: id), body: .json(body)) {
                case .ok: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .book(id):
                switch try await client.update_book_api_v1_library_books__book_id__patch(path: .init(book_id: id), body: .json(body)) {
                case .ok: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func delete(_ ref: MediaRef, deleteFiles: Bool) async throws {
        try await call {
            switch ref {
            case let .movie(id):
                switch try await client.delete_movie_api_v1_library_movies__movie_id__delete(
                    path: .init(movie_id: id), query: .init(delete_files: deleteFiles)
                ) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .series(id):
                switch try await client.delete_series_api_v1_library_series__series_id__delete(
                    path: .init(series_id: id), query: .init(delete_files: deleteFiles)
                ) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .book(id):
                switch try await client.delete_book_api_v1_library_books__book_id__delete(
                    path: .init(book_id: id), query: .init(delete_files: deleteFiles)
                ) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func triggerSearch(_ ref: MediaRef) async throws {
        try await call {
            switch try await client.trigger_search_api_v1_library__app___item_id__search_post(
                path: .init(app: ref.app.rawValue, item_id: ref.id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {
        try await call {
            switch try await client.season_monitor_api_v1_library_series__series_id__seasons__season__monitor_post(
                path: .init(series_id: series, season: season), body: .json(.init(monitored: monitored))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func searchSeason(series: Int, season: Int) async throws {
        try await call {
            switch try await client.season_search_api_v1_library_series__series_id__seasons__season__search_post(
                path: .init(series_id: series, season: season)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {
        try await call {
            switch try await client.episodes_monitor_api_v1_library_episodes_monitor_patch(
                body: .json(.init(ids: ids, monitored: monitored))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func searchEpisodes(_ ids: [Int]) async throws {
        try await call {
            switch try await client.episodes_search_api_v1_library_episodes_search_post(body: .json(.init(ids: ids))) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}
