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
/// queue item links to. Lidarr's library has two levels: the Music tab's
/// cards are artists, while every row elsewhere (calendar, history, wanted,
/// recently added, the queue) is an album.
public enum MediaRef: Hashable, Sendable {
    case movie(Int)
    case series(Int)
    case book(Int)
    case artist(Int)
    case album(Int)

    /// The library title behind an arr's own library id: the movie, the
    /// series, the book, or for Lidarr the album, which is what recently
    /// added, Wanted and the calendar carry.
    public init?(app: String, id: Int?) {
        guard let id else { return nil }
        switch app {
        case "radarr": self = .movie(id)
        case "sonarr": self = .series(id)
        case "readarr": self = .book(id)
        case "lidarr": self = .album(id)
        default: return nil
        }
    }

    public var app: ArrApp {
        switch self {
        case .movie: .radarr
        case .series: .sonarr
        case .book: .readarr
        case .artist, .album: .lidarr
        }
    }

    public var id: Int {
        switch self {
        case let .movie(id), let .series(id), let .book(id), let .artist(id), let .album(id): id
        }
    }
}

public typealias BookDetail = Components.Schemas.BookDetailOut
public typealias BookEdition = Components.Schemas.BookEditionOut
public typealias BookFile = Components.Schemas.BookFileOut
public typealias BookSeries = Components.Schemas.BookSeriesOut
public typealias SeriesBook = Components.Schemas.SeriesBookOut
public typealias AuthorSummary = Components.Schemas.AuthorOut
public typealias AuthorDetail = Components.Schemas.AuthorDetailOut
public typealias EditionChoice = Components.Schemas.EditionChoiceOut
public typealias TitleSubtitles = Components.Schemas.TitleSubtitlesOut
public typealias SubtitleTrack = Components.Schemas.SubtitleTrackOut
public typealias EpisodeSubtitles = Components.Schemas.EpisodeSubtitlesOut

/// What a subtitle download is for.
public enum SubtitleTarget: Hashable, Sendable {
    case movie(Int)
    case episode(series: Int, episode: Int)
}

extension RecentItem {
    public var ref: MediaRef? { MediaRef(app: app, id: library_id) }
}

extension HistoryItem {
    public var ref: MediaRef? {
        if let movie_id { return .movie(movie_id) }
        if let series_id { return .series(series_id) }
        if let book_id { return .book(book_id) }
        if let album_id { return .album(album_id) }
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
    /// Plex's rating key, for asking which episodes of a show were watched.
    public var key: String?

    public init(watched: Bool, progress: Double, url: URL?, key: String? = nil) {
        self.watched = watched
        self.progress = progress
        self.url = url
        self.key = key
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
            return Watched(watched: item.watched ?? false, progress: item.progress ?? 0, url: url, key: item.key)
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
    // Bazarr, per title. Fails when Bazarr is not configured; the views hide
    // the section then instead of plumbing a flag through every screen.
    func movieSubtitles(_ id: Int) async throws -> TitleSubtitles
    func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles]
    func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws
    func deleteEpisodeFile(_ fileID: Int) async throws
    // Readarr authors and editions
    func authorDetail(_ id: Int) async throws -> AuthorDetail
    func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary
    func bookEditions(edition: String) async throws -> [EditionChoice]
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws
    func searchEpisodes(_ ids: [Int]) async throws
}
