import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func form(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

private let plex = ServiceConnection(url: "http://10.0.0.5:32400", apiKey: "plextoken")
private let bazarr = ServiceConnection.arr("http://10.0.0.5:6767")
private let radarr = ServiceConnection.arr("http://10.0.0.5:7878")

// MARK: - Watch statistics (test_watchstats.py)

struct PlexBazarrWatchStatsTests {
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        return Int(date.timeIntervalSince1970)
    }

    static let history: [JSON] = [
        // two episodes of one show by the owner, a Monday evening
        ["type": "episode", "grandparentKey": "/library/metadata/10", "grandparentTitle": "Slow Horses",
         "accountID": 1, "viewedAt": JSON(at(2026, 9, 21, 21, 0))],
        ["type": "episode", "grandparentKey": "/library/metadata/10", "grandparentTitle": "Slow Horses",
         "accountID": 1, "viewedAt": JSON(at(2026, 9, 21, 22, 0))],
        // a movie by someone else, Saturday afternoon
        ["type": "movie", "key": "/library/metadata/20", "title": "Heat", "accountID": 7,
         "viewedAt": JSON(at(2026, 9, 19, 15, 30))],
        // a track, which is not TV or film
        ["type": "track", "key": "/library/metadata/30", "title": "Song", "accountID": 1,
         "viewedAt": JSON(at(2026, 9, 19, 9, 0))],
    ]

    static let titles: [String: WatchStatsBuilder.Title] = [
        "10": .init(duration: 45 * 60_000, guids: ["tvdb:111", "imdb:tt1"]),
        "20": .init(duration: 170 * 60_000, guids: ["tmdb:949"]),
    ]

    static func stats(movies: [String: JSON]? = nil, timeZone: String = "Europe/Copenhagen") -> WatchStats {
        WatchStatsBuilder.build(
            history: history, titles: titles, accounts: [1: "owner", 7: ""],
            movies: movies ?? ["tmdb:949": ["id": 5, "images": []]],
            series: ["tvdb:111": ["id": 9, "images": []]],
            days: 30, timeZone: timeZone
        )
    }

    @Test func totalsCountOnlyFilmAndTVAndEstimateHoursFromRuntimes() {
        let out = Self.stats()
        #expect(out.plays == 3 && out.movies == 1 && out.episodes == 2)
        #expect(out.hours == 4.3) // round((2 * 45 + 170) / 60, 1)
    }

    @Test func usersRankedByPlaysWithAFallbackName() {
        let users = Self.stats().users ?? []
        #expect(users.map(\.name) == ["owner", "#7"])
        #expect(users.first?.plays == 2 && users.first?.hours == 1.5)
    }

    @Test func topTitlesLinkToTheArrsThroughTheirGuids() {
        let out = Self.stats()
        #expect(out.top_shows == [WatchTitle(hours: 1.5, plays: 2, series_id: 9, title: "Slow Horses")])
        #expect(out.top_movies?.first?.movie_id == 5)
        let unlinked = Self.stats(movies: [:]).top_movies?.first
        #expect(unlinked?.movie_id == nil && unlinked?.title == "Heat")
    }

    @Test func whenIsBucketedInTheAskedZone() {
        let out = Self.stats()
        #expect(out.by_weekday?[0] == 2) // Monday
        #expect(out.by_weekday?[5] == 1) // Saturday
        #expect(out.by_hour?[21] == 1 && out.by_hour?[22] == 1 && out.by_hour?[15] == 1)
        let utc = Self.stats(timeZone: "UTC")
        #expect(utc.by_hour?[19] == 1) // 21:00 in Copenhagen is 19:00 UTC in September
        #expect(Self.stats(timeZone: "Not/AZone").by_hour == utc.by_hour)
    }

    @Test func hoursRoundAsPythonDoes() {
        #expect(WatchStatsBuilder.tenths(0.25) == 0.2) // a true tie goes to even
        #expect(WatchStatsBuilder.tenths(0.35) == 0.3) // 0.35 is a hair under as a double
        #expect(WatchStatsBuilder.hours(5_400_000) == 1.5)
    }

    @Test func statsAskPlexTheArrsThatAreSetUpAndKeepTheLastAnswer() async throws {
        let (direct, transport) = backend(["plex": plex, "radarr": radarr])
        transport.on("GET /status/sessions/history/all", json: """
        {"MediaContainer": {"Metadata": [
          {"type": "movie", "key": "/library/metadata/20", "title": "Heat", "accountID": 1, "viewedAt": 1758290000}
        ]}}
        """)
        transport.on("GET /library/sections", json: #"{"MediaContainer": {"Directory": [{"key": "1", "type": "movie"}, {"key": "2", "type": "artist"}]}}"#)
        transport.on("GET /library/sections/1/all", json: """
        {"MediaContainer": {"Metadata": [{"ratingKey": "20", "duration": 10200000, "Guid": [{"id": "tmdb://949"}]}]}}
        """)
        transport.on("GET /accounts", json: #"{"MediaContainer": {"Account": [{"id": 1, "name": "owner"}]}}"#)
        transport.on("GET /api/v3/movie", json: """
        [{"id": 5, "tmdbId": 949, "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/h.jpg"}]}]
        """)

        let block = try await direct.watchStats(days: 0, timeZone: "UTC")
        let stats = try #require(block.value)
        #expect(block.offlineReason == nil && block.staleAge == nil)
        #expect(stats.days == 0 && stats.hours == 2.8)
        #expect(stats.top_movies == [
            WatchTitle(hours: 2.8, movie_id: 5, plays: 1, poster: "https://image.tmdb.org/t/p/w500/h.jpg", title: "Heat"),
        ])
        let asked = try #require(transport.requests.first { $0.url?.path() == "/status/sessions/history/all" })
        // all time starts at the epoch; `>` travels percent-encoded, as httpx sent it
        #expect(query(asked)["viewedAt>"] == "0")
        #expect(query(asked)["X-Plex-Container-Size"] == "20000")
        #expect(asked.value(forHTTPHeaderField: "X-Plex-Token") == "plextoken")
        // music sections are not counted, and Sonarr is not set up so not asked
        #expect(!transport.requests.contains { $0.url?.path().hasSuffix("/sections/2/all") == true })
        #expect(!transport.requests.contains { $0.url?.path().contains("/series") == true })

        // Plex away: the last answer, aged
        direct.cache.remove(["plex:stats:0:UTC"])
        transport.on("GET /status/sessions/history/all", status: 500, json: "")
        let stale = try await direct.watchStats(days: 0, timeZone: "UTC")
        #expect(stale.value == stats && stale.staleAge != nil)
    }
}

// MARK: - Watchlist

struct PlexBazarrWatchlistTests {
    @Test func marksWhatTheArrsHaveAndSkipsWhatTheyCannotAdd() {
        let items: [JSON] = [
            ["type": "movie", "title": "Heat", "year": 1995,
             "Guid": [["id": "tmdb://949"], ["id": "imdb://tt0113277"]],
             "thumb": "https://image.tmdb.org/t/p/original/x.jpg"],
            ["type": "show", "title": "Slow Horses", "Guid": [["id": "tvdb://111"]]],
            ["type": "show", "title": "No ids", "Guid": []],
            ["type": "movie", "title": "Dune", "Guid": [["id": "tmdb://438631"]]],
        ]
        let rows = WatchStatsBuilder.watchlistRows(
            items,
            movies: [["id": 5, "tmdbId": 949, "hasFile": true, "monitored": true]],
            series: [["id": 9, "tvdbId": 111, "monitored": true, "statistics": ["percentOfEpisodes": 50]]]
        )
        #expect(rows.map(\.title) == ["Heat", "Slow Horses", "Dune"])
        let (heat, horses, dune) = (rows[0], rows[1], rows[2])
        #expect(heat.kind == "movie" && heat.remote_id == 949 && heat.imdb_id == "tt0113277" && heat.tmdb_id == 949)
        #expect(heat.in_library == true && heat.library_id == 5 && heat.has_file == true && heat.monitored == true)
        #expect(heat.poster == "https://image.tmdb.org/t/p/w500/x.jpg")
        #expect(heat.quality_profile_id == nil && heat.editions == [])
        #expect(horses.kind == "series" && horses.remote_id == 111 && horses.has_file == false)
        #expect(dune.in_library == false && dune.library_id == nil && dune.has_file == nil)
    }

    @Test func theWatchlistIsAskedOfPlexTVWithTheServersToken() async throws {
        let (direct, transport) = backend(["plex": plex])
        transport.on("GET /library/sections/watchlist/all") { request in
            #expect(request.url?.host() == "discover.provider.plex.tv")
            #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "plextoken")
            #expect(query(request)["X-Plex-Container-Start"] == "0")
            return ServiceResponse(status: 200, headers: [:], data: Data("""
            {"MediaContainer": {"totalSize": 1, "Metadata": [
              {"type": "movie", "title": "Heat", "Guid": [{"id": "tmdb://949"}],
               "thumb": "https://metadata-static.plex.tv/a/b.jpg", "summary": "LA."}]}}
            """.utf8))
        }
        let rows = try await direct.plexWatchlist()
        #expect(rows.map(\.title) == ["Heat"])
        #expect(rows.first?.poster == "https://metadata-static.plex.tv/a/b.jpg")
        #expect(rows.first?.in_library == false && rows.first?.overview == "LA.")
        // one short page is the whole list
        #expect(transport.requests.count == 1)
    }

    @Test func aWatchlistRefusalSaysWhatPlexTVNeeds() async throws {
        let (direct, transport) = backend(["plex": plex])
        transport.on("GET /library/sections/watchlist/all", status: 401, json: "")
        await #expect(throws: APIError.refused("unauthorized (the watchlist needs a plex.tv token)")) {
            try await direct.plexWatchlist()
        }
        // a 5xx is an outage like any other; a refusal names the watchlist
        transport.on("GET /library/sections/watchlist/all", status: 404, json: "")
        await #expect(throws: APIError.refused("watchlist: HTTP 404")) { try await direct.plexWatchlist() }
    }
}

// MARK: - Watched episodes

struct PlexBazarrWatchedEpisodesTests {
    @Test func onlyPlayedEpisodesWithANumberCount() async throws {
        let (direct, transport) = backend(["plex": plex])
        transport.on("GET /library/metadata/42/allLeaves", json: """
        {"MediaContainer": {"Metadata": [
          {"parentIndex": 1, "index": 1, "viewCount": 2},
          {"parentIndex": 1, "index": 2},
          {"parentIndex": 1, "index": 3, "viewCount": 0},
          {"index": 4, "viewCount": 1},
          {"parentIndex": 2, "index": 1, "viewCount": 1}
        ]}}
        """)
        #expect(try await direct.watchedEpisodes(key: "42") == ["1x1", "2x1"])
    }

    @Test func aKeyThatIsNotARatingKeyIsRefused() async {
        let (direct, _) = backend(["plex": plex])
        await #expect(throws: APIError.unexpectedStatus(422)) { try await direct.watchedEpisodes(key: "../x") }
    }

    @Test func plexAwayIsNothingWatched() async throws {
        let (direct, _) = backend(["plex": plex])
        #expect(try await direct.watchedEpisodes(key: "42") == [])
    }
}

// MARK: - Bazarr tools

struct PlexBazarrSubtitleToolsTests {
    @Test func theWantedListComesAPageAtATimeWithItsTotal() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("GET /api/episodes/wanted", json: """
        {"total": 31, "data": [{"sonarrEpisodeId": 7, "sonarrSeriesId": 3, "seriesTitle": "Severance",
          "episode_number": "1x02", "episodeTitle": "Half Loop", "missing_subtitles": [{"name": "Danish"}]}]}
        """)
        let page = try await direct.subtitlesWanted(kind: .episode, start: 20, length: 10)
        #expect(page.total == 31)
        #expect(page.items == [SubtitleItem(
            id: 7, kind: "episode", missing: ["Danish"], series_id: 3, subtitle: "1x02 Half Loop", title: "Severance"
        )])
        #expect(query(transport.requests[0]) == ["start": "20", "length": "10"])
        await #expect(throws: APIError.unexpectedStatus(422)) {
            try await direct.subtitlesWanted(kind: .movie, start: 0, length: 500)
        }
    }

    @Test func searchingEverythingRunsBazarrsOwnJob() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("POST /api/system/tasks", status: 204, json: "")
        try await direct.searchAllSubtitles(kind: .episode)
        #expect(form(transport.requests[0]) == "taskid=wanted_search_missing_subtitles_series")
        #expect(transport.requests[0].value(forHTTPHeaderField: "X-API-KEY") == "secret")
    }

    @Test func profilesListTheirLanguagesInOrder() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("GET /api/system/languages/profiles", json: """
        [{"profileId": 2, "name": "Nordic", "items": [{"language": "da"}, {"language": ""}, {"language": "sv"}]},
         {"profileId": 3}]
        """)
        #expect(try await direct.languageProfiles() == [
            LanguageProfile(id: 2, languages: ["da", "sv"], name: "Nordic"),
            LanguageProfile(id: 3, languages: [], name: ""),
        ])
    }

    @Test func titlesComeSortedWithTheirProfileAndWithoutTheIdless() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("GET /api/movies", json: """
        {"data": [{"radarrId": 5, "title": "heat", "year": "1995", "profileId": 2},
                  {"radarrId": 0, "title": "Ghost"}]}
        """)
        transport.on("GET /api/series", json: #"{"data": [{"sonarrSeriesId": 9, "title": "Andor", "year": "", "profileId": null}]}"#)
        let titles = try await direct.subtitleTitles()
        #expect(titles == [
            SubtitleTitle(id: 9, kind: .series, profile_id: nil, title: "Andor", year: nil),
            SubtitleTitle(id: 5, kind: .movie, profile_id: 2, title: "heat", year: "1995"),
        ])
        #expect(transport.requests.allSatisfy { query($0) == ["start": "0", "length": "-1"] })
    }

    @Test func aProfileGoesOnEveryIdByPosition() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("GET /api/system/languages/profiles", json: #"[{"profileId": 2, "name": "Nordic"}]"#)
        transport.on("POST /api/movies", status: 204, json: "")
        transport.on("POST /api/series", status: 204, json: "")
        try await direct.assignProfile(movies: true, ids: [5, 6], profileID: 2)
        #expect(form(transport.requests.last!) == "radarrid=5&radarrid=6&profileid=2&profileid=2")
        // none takes it off, and needs no check against the profiles
        let asked = transport.requests.count
        try await direct.assignProfile(movies: false, ids: [9], profileID: nil)
        #expect(transport.requests.count == asked + 1)
        #expect(form(transport.requests.last!) == "seriesid=9&profileid=")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test func anUnknownProfileIsRefusedBeforeAnythingIsWritten() async throws {
        let (direct, transport) = backend(["bazarr": bazarr])
        transport.on("GET /api/system/languages/profiles", json: #"[{"profileId": 2}]"#)
        await #expect(throws: APIError.refused("no such language profile")) {
            try await direct.assignProfile(movies: true, ids: [5], profileID: 8)
        }
        #expect(!transport.requests.contains { $0.httpMethod == "POST" })
        await #expect(throws: APIError.unexpectedStatus(422)) {
            try await direct.assignProfile(movies: true, ids: [], profileID: 2)
        }
    }
}
