import ArrdeckAPI
import Foundation

public typealias LanguageProfile = Components.Schemas.LanguageProfileOut
public typealias SubtitleTitle = Components.Schemas.SubtitleTitleOut
public typealias SubtitleWanted = Components.Schemas.SubtitleWantedOut

/// Everything Bazarr is missing, and language profiles handed out in bulk.
public protocol SubtitleToolsAPI: Sendable {
    func subtitlesWanted(kind: SubtitleKind, start: Int, length: Int) async throws -> SubtitleWanted
    func searchAllSubtitles(kind: SubtitleKind) async throws
    func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws
    func languageProfiles() async throws -> [LanguageProfile]
    func subtitleTitles() async throws -> [SubtitleTitle]
    /// nil takes the profile off: Bazarr then fetches nothing for them.
    func assignProfile(movies: Bool, ids: [Int], profileID: Int?) async throws
}

/// Which titles the profile editor shows and which are picked.
public struct ProfilePicks: Sendable, Equatable {
    public var movies = false
    public var onlyUnset = true
    public var picked: Set<Int> = []

    public init() {}

    public func shown(_ titles: [SubtitleTitle]) -> [SubtitleTitle] {
        titles.filter { ($0.kind == .movie) == movies && (!onlyUnset || $0.profile_id == nil) }
    }

    public func unsetCount(_ titles: [SubtitleTitle]) -> Int {
        titles.filter { ($0.kind == .movie) == movies && $0.profile_id == nil }.count
    }

    public func allPicked(_ titles: [SubtitleTitle]) -> Bool {
        let rows = shown(titles)
        return !rows.isEmpty && rows.allSatisfy { picked.contains($0.id) }
    }

    /// Everything shown, or nothing when everything shown already is.
    public mutating func toggleAll(_ titles: [SubtitleTitle]) {
        picked = allPicked(titles) ? [] : Set(shown(titles).map(\.id))
    }

    public mutating func toggle(_ id: Int) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    /// Switching between movies and shows starts the pick over; the ids are different kinds.
    public mutating func show(movies: Bool) {
        guard movies != self.movies else { return }
        self.movies = movies
        picked = []
    }
}
