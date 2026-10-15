import ArrdeckData
import Foundation

/// The power tools, from the server's tools.py: the arrs' import list
/// exclusions, the release name tester, and the season grid.
extension DirectBackend: ToolsAPI {
    /// Everything the arrs set up keep off their lists, newest first. An arr
    /// that is down leaves its rows out, not the list.
    public func exclusions() async throws -> [Exclusion] {
        let apps = ArrApp.allCases.filter { registry.isConfigured($0.rawValue) }
        let pages = await eachArr(apps) { app, client in try await client.get(ToolsPort.exclusionPath(app)) }
        var rows: [Exclusion] = []
        for app in apps {
            guard let page = pages[app] else { continue }
            // a paged answer from some versions, a bare list from others
            let items = if case .object = page { page["records"].array } else { page.array }
            rows += items.compactMap { ToolsPort.exclusion(app: app, $0) }
        }
        return DashboardPort.stableSorted(rows) { $0.id > $1.id }
    }

    /// Lets the arr's lists add the title again.
    public func removeExclusion(app: String, id: Int) async throws {
        try await call {
            guard let arr = ArrApp(rawValue: app) else { throw APIError.refused("unknown app '\(app)'") }
            try await registry.arr(app).send("DELETE", "\(ToolsPort.exclusionPath(arr))/\(id)")
            // the server dropped its cached Radarr recommendations here;
            // nothing on the device keeps them
        }
    }

    /// What Radarr or Sonarr makes of a release name: title, quality, custom
    /// formats and score, and which library title it would go to.
    public func parse(app: ArrApp, title: String) async throws -> ParseResult {
        try await call {
            guard app == .radarr || app == .sonarr else { throw APIError.refused("unknown app '\(app.rawValue)'") }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw APIError.refused("title is empty") }
            return ToolsPort.parse(app: app, title: title, try await registry.arr(app.rawValue).get("/parse", query: ["title": title]))
        }
    }

    /// Every show with its seasons, for monitoring many at once.
    public func seasonGrid() async throws -> [SeasonGridRow] {
        try await call {
            let series = try await registry.arr("sonarr").get("/series").array
            return ToolsPort.byText(series) { $0["sortTitle"].string ?? "" }.compactMap(ToolsPort.seasonRow)
        }
    }
}

/// tools.py's mapping.
enum ToolsPort {
    /// Where each arr keeps the titles its lists may not add back.
    static func exclusionPath(_ app: ArrApp) -> String {
        app == .radarr ? "/exclusions" : "/importlistexclusion"
    }

    static func exclusion(app: ArrApp, _ entry: JSON) -> Exclusion? {
        guard let id = entry["id"].int else { return nil }
        switch app {
        case .radarr:
            return Exclusion(
                app: app.rawValue, id: id, remote_id: remoteID(entry["tmdbId"]), title: entry["movieTitle"].string,
                year: entry["movieYear"].nonZero
            )
        case .sonarr:
            return Exclusion(app: app.rawValue, id: id, remote_id: remoteID(entry["tvdbId"]), title: entry["title"].string)
        case .readarr, .lidarr:
            let title = entry["authorName"].nonEmpty ?? entry["artistName"].nonEmpty
                ?? entry["title"].string
            return Exclusion(app: app.rawValue, id: id, remote_id: entry["foreignId"].string, title: title)
        }
    }

    private static func remoteID(_ value: JSON) -> String? {
        value.truthy ? value.printed : nil
    }

    static func parse(app: ArrApp, title: String, _ answer: JSON) -> ParseResult {
        let info = answer["parsedMovieInfo"].truthy ? answer["parsedMovieInfo"] : answer["parsedEpisodeInfo"]
        let quality = info["quality"]["quality"]
        let languages = info["languages"].truthy ? info["languages"] : answer["languages"]
        let match = answer["movie"].truthy ? answer["movie"] : answer["series"]
        return ParseResult(
            app: app.rawValue,
            custom_format_score: answer["customFormatScore"].whole ?? 0,
            custom_formats: answer["customFormats"].array.compactMap { $0["name"].nonEmpty },
            edition: info["edition"].nonEmpty,
            episodes: info["episodeNumbers"].array.compactMap(\.int),
            full_season: info["fullSeason"].truthy,
            languages: languages.array.compactMap { $0["name"].nonEmpty }.filter { $0 != "Unknown" },
            match_episodes: answer["episodes"].array.map { episode in
                let code = DashboardPort.episodeCode(episode)
                return "\(code) \(episode["title"].string ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
            },
            match_id: match["id"].int,
            match_title: match["title"].string,
            parsed_title: app == .radarr ? info["movieTitles"][0].string : info["seriesTitle"].string,
            quality: quality["name"].string,
            release_group: info["releaseGroup"].string,
            resolution: quality["resolution"].nonZero,
            season: app == .sonarr ? info["seasonNumber"].int : nil,
            source: quality["source"].string,
            title: title,
            year: info["year"].nonZero
        )
    }

    static func seasonRow(_ series: JSON) -> SeasonGridRow? {
        guard let id = series["id"].int else { return nil }
        let seasons = DashboardPort.stableSorted(series["seasons"].array) {
            ($0["seasonNumber"].int ?? 0) < ($1["seasonNumber"].int ?? 0)
        }
        return SeasonGridRow(
            id: id,
            monitored: series["monitored"].bool ?? false,
            poster: Artwork.poster(series["images"]),
            seasons: seasons.map { season in
                let stats = season["statistics"]
                return .init(
                    have: stats["episodeFileCount"].int ?? 0, monitored: season["monitored"].bool ?? false,
                    number: season["seasonNumber"].int ?? 0, total: stats["totalEpisodeCount"].int ?? 0
                )
            },
            status: series["status"].string,
            title: series["title"].string
        )
    }

    /// Sorted by a text key code point by code point, as Python compares
    /// strings, ties in the order they came.
    static func byText(_ items: [JSON], _ key: (JSON) -> String) -> [JSON] {
        DashboardPort.stableSorted(items) { key($0).unicodeScalars.lexicographicallyPrecedes(key($1).unicodeScalars) }
    }
}
