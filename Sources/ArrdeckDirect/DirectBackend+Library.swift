import ArrdeckData
import Foundation

extension DirectBackend: LibraryAPI {
    public func movieDetail(_ id: Int) async throws -> MovieDetail {
        throw APIError.needsServer
    }

    public func movieCredits(_ id: Int) async throws -> Credits {
        throw APIError.needsServer
    }

    public func seriesDetail(_ id: Int) async throws -> SeriesDetail {
        throw APIError.needsServer
    }

    public func bookDetail(_ id: Int) async throws -> BookDetail {
        throw APIError.needsServer
    }

    public func episodes(series: Int, season: Int) async throws -> [Episode] {
        throw APIError.needsServer
    }

    public func options(_ app: ArrApp) async throws -> Options {
        throw APIError.needsServer
    }

    public func watched() async throws -> Block<WatchedMap> {
        throw APIError.needsServer
    }

    public func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws {
        throw APIError.needsServer
    }

    public func delete(_ ref: MediaRef, deleteFiles: Bool) async throws {
        throw APIError.needsServer
    }

    public func triggerSearch(_ ref: MediaRef) async throws {
        throw APIError.needsServer
    }

    public func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {
        throw APIError.needsServer
    }

    public func searchSeason(series: Int, season: Int) async throws {
        throw APIError.needsServer
    }

    public func movieSubtitles(_ id: Int) async throws -> TitleSubtitles {
        throw APIError.needsServer
    }

    public func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles] {
        throw APIError.needsServer
    }

    public func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws {
        throw APIError.needsServer
    }

    public func deleteEpisodeFile(_ fileID: Int) async throws {
        throw APIError.needsServer
    }

    public func authorDetail(_ id: Int) async throws -> AuthorDetail {
        throw APIError.needsServer
    }

    public func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary {
        throw APIError.needsServer
    }

    public func bookEditions(edition: String) async throws -> [EditionChoice] {
        throw APIError.needsServer
    }

    public func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {
        throw APIError.needsServer
    }

    public func searchEpisodes(_ ids: [Int]) async throws {
        throw APIError.needsServer
    }
}
