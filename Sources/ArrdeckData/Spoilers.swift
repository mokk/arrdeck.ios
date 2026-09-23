import ArrdeckAPI
import Foundation

/// Which episodes of one show Plex has seen watched, for spoiler protection.
/// Its own protocol so the detail screens can ask for it without every test
/// fake of LibraryAPI having to answer.
public protocol WatchedEpisodesAPI: Sendable {
    func watchedEpisodes(key: String) async throws -> Set<String>
}

extension LiveAPI: WatchedEpisodesAPI {
    public func watchedEpisodes(key: String) async throws -> Set<String> {
        try await call {
            switch try await client.watched_episodes_api_v1_watched_episodes_get(query: .init(key: key)) {
            case let .ok(ok): Set((try ok.body.json.data ?? []).map { SpoilerGuard.key(season: $0.season, episode: $0.episode) })
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

public enum SpoilerGuard {
    public static func key(season: Int, episode: Int) -> String { "\(season)x\(episode)" }

    /// Whether an episode's title and summary stay hidden. Without an answer
    /// from Plex everything counts as unwatched, which errs on the safe side.
    public static func hides(season: Int, episode: Int, mode: Spoilers, watched: Set<String>?) -> Bool {
        switch mode {
        case .off: false
        case .always: true
        case .unwatched: !(watched ?? []).contains(key(season: season, episode: episode))
        }
    }
}
