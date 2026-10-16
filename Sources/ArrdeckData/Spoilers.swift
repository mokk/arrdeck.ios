import ArrdeckAPI
import Foundation

/// Which episodes of one show Plex has seen watched, for spoiler protection.
/// Its own protocol so the detail screens can ask for it without every test
/// fake of LibraryAPI having to answer.
public protocol WatchedEpisodesAPI: Sendable {
    func watchedEpisodes(key: String) async throws -> Set<String>
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
