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

extension LiveAPI: SubtitleToolsAPI {
    public func subtitlesWanted(kind: SubtitleKind, start: Int, length: Int) async throws -> SubtitleWanted {
        try await call {
            switch try await client.subtitles_wanted_api_v1_subtitles_wanted_get(
                query: .init(kind: kind == .movie ? .movie : .episode, start: start, length: length)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func searchAllSubtitles(kind: SubtitleKind) async throws {
        try await call {
            switch try await client.subtitles_search_all_api_v1_subtitles_wanted_search_post(
                query: .init(kind: kind == .movie ? .movie : .episode)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func languageProfiles() async throws -> [LanguageProfile] {
        try await call {
            switch try await client.language_profiles_api_v1_subtitles_profiles_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func subtitleTitles() async throws -> [SubtitleTitle] {
        try await call {
            switch try await client.subtitle_titles_api_v1_subtitles_titles_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func assignProfile(movies: Bool, ids: [Int], profileID: Int?) async throws {
        try await call {
            switch try await client.assign_profile_api_v1_subtitles_profile_put(
                body: .json(.init(ids: ids, kind: movies ? .movie : .series, profile_id: profileID))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
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
