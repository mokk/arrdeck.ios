import ArrdeckData
import Foundation

/// Bazarr's tools beyond the dashboard card: the whole wanted list a page at
/// a time, its own search-everything jobs, and language profiles handed out
/// in bulk. Ported from subtitles.py; `searchSubtitles` is the dashboard's
/// (DirectBackend+Dashboard.swift), the same call either way.
extension DirectBackend: SubtitleToolsAPI {
    /// Bazarr's own jobs that go through the whole wanted list.
    static let searchAllTasks: [SubtitleKind: String] = [
        .movie: "wanted_search_missing_subtitles_movies",
        .episode: "wanted_search_missing_subtitles_series",
    ]

    /// Everything missing subtitles, a page at a time — the dashboard only
    /// shows the first few. Rows as the dashboard card has them.
    public func subtitlesWanted(kind: SubtitleKind, start: Int, length: Int) async throws -> SubtitleWanted {
        // the server's query bounds, refused as it refused them
        guard start >= 0, (1 ... 200).contains(length) else { throw APIError.unexpectedStatus(422) }
        return try await call {
            let page = try await registry.bazarr().get(
                kind == .movie ? "/movies/wanted" : "/episodes/wanted",
                query: ["start": "\(start)", "length": "\(length)"]
            )
            let row = kind == .movie ? DashboardCards.wantedMovie : DashboardCards.wantedEpisode
            return SubtitleWanted(items: page["data"].array.map(row), total: page["total"].whole ?? 0)
        }
    }

    public func searchAllSubtitles(kind: SubtitleKind) async throws {
        try await call {
            try await registry.bazarr().sendForm("POST", "/system/tasks", [("taskid", Self.searchAllTasks[kind] ?? "")])
        }
    }

    public func languageProfiles() async throws -> [LanguageProfile] {
        try await call {
            try await registry.bazarr().get("/system/languages/profiles").array.map(Self.languageProfile)
        }
    }

    static func languageProfile(_ profile: JSON) -> LanguageProfile {
        LanguageProfile(
            id: profile["profileId"].int ?? 0,
            languages: profile["items"].array.compactMap { ($0["language"]).nonEmpty },
            name: profile["name"].string ?? ""
        )
    }

    /// Every movie and series with its language profile, so titles without
    /// one — which Bazarr never fetches anything for — can be given one in
    /// bulk.
    public func subtitleTitles() async throws -> [SubtitleTitle] {
        try await call {
            let bazarr = try registry.bazarr()
            let everything: [String: String?] = ["start": "0", "length": "-1"]
            async let movies = bazarr.get("/movies", query: everything)
            async let series = bazarr.get("/series", query: everything)
            let rows = try await movies["data"].array.map { Self.subtitleTitle(.movie, $0) }
                + series["data"].array.map { Self.subtitleTitle(.series, $0) }
            return DashboardPort.stableSorted(rows.filter { $0.id != 0 }) {
                ($0.title ?? "").lowercased() < ($1.title ?? "").lowercased()
            }
        }
    }

    static func subtitleTitle(_ kind: SubtitleTitle.kindPayload, _ row: JSON) -> SubtitleTitle {
        // Bazarr writes the year as text; a number is taken as one too
        let year = row["year"].nonEmpty ?? row["year"].nonZero.map(String.init)
        return SubtitleTitle(
            id: row[kind == .movie ? "radarrId" : "sonarrSeriesId"].int ?? 0,
            kind: kind,
            profile_id: row["profileId"].int,
            title: row["title"].string ?? "",
            year: year
        )
    }

    /// nil takes the profile off. An id Bazarr does not know is refused
    /// before anything is written, as the server did.
    public func assignProfile(movies: Bool, ids: [Int], profileID: Int?) async throws {
        guard (1 ... 1000).contains(ids.count) else { throw APIError.unexpectedStatus(422) }
        try await call {
            let bazarr = try registry.bazarr()
            if let profileID {
                let known = try await bazarr.get("/system/languages/profiles").array.compactMap { $0["profileId"].int }
                guard known.contains(profileID) else { throw APIError.refused("no such language profile") }
            }
            try await bazarr.sendForm("POST", movies ? "/movies" : "/series", Self.profileForm(movies: movies, ids: ids, profileID: profileID))
            forget("subtitles")
        }
    }

    /// Bazarr pairs the id and profile lists by position and reads an empty
    /// profile as none, so every id carries its own copy of the value.
    static func profileForm(movies: Bool, ids: [Int], profileID: Int?) -> [(String, String)] {
        let key = movies ? "radarrid" : "seriesid"
        let value = profileID.map(String.init) ?? ""
        return ids.map { (key, String($0)) } + ids.map { _ in ("profileid", value) }
    }
}
