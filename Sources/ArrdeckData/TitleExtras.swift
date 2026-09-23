import ArrdeckAPI
import Foundation

/// The per-title extras: Bazarr subtitles, episode files, Readarr authors
/// and editions. Split from Library.swift to keep that file readable.
extension LiveAPI {
    public func movieSubtitles(_ id: Int) async throws -> TitleSubtitles {
        try await call {
            switch try await client.movie_subtitles_api_v1_subtitles_movie__radarr_id__get(path: .init(radarr_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles] {
        try await call {
            switch try await client.series_subtitles_api_v1_subtitles_series__series_id__get(path: .init(series_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws {
        try await call {
            switch target {
            case let .movie(id):
                switch try await client.movie_subtitle_download_api_v1_subtitles_movie__radarr_id__download_post(
                    path: .init(radarr_id: id), body: .json(.init(language: language))
                ) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .episode(series, episode):
                switch try await client.episode_subtitle_download_api_v1_subtitles_series__series_id__episodes__episode_id__download_post(
                    path: .init(series_id: series, episode_id: episode), body: .json(.init(language: language))
                ) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func deleteEpisodeFile(_ fileID: Int) async throws {
        try await call {
            switch try await client.delete_episode_file_api_v1_library_episodes_files__file_id__delete(path: .init(file_id: fileID)) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func authorDetail(_ id: Int) async throws -> AuthorDetail {
        try await call {
            switch try await client.author_detail_api_v1_library_authors__author_id__get(path: .init(author_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary {
        try await call {
            let items = monitorNewItems.flatMap { Components.Schemas.AuthorUpdateIn.monitor_new_itemsPayload(rawValue: $0) }
            switch try await client.update_author_api_v1_library_authors__author_id__patch(
                path: .init(author_id: id), body: .json(.init(monitor_new_items: items, monitored: monitored))
            ) {
            case let .ok(ok): return try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func bookEditions(edition: String) async throws -> [EditionChoice] {
        try await call {
            switch try await client.book_editions_api_v1_search_books_editions_get(query: .init(edition: edition)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension TitleSubtitles {
    /// Anything to show at all: Bazarr tracks the title and its profile
    /// wants at least one language.
    public var hasLanguages: Bool { !(present ?? []).isEmpty || !(missing ?? []).isEmpty }
}
