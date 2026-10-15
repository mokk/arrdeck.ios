import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

private func body(_ request: URLRequest?) throws -> JSON {
    try JSON(data: try #require(request?.httpBody))
}

private func query(_ request: URLRequest?, _ name: String) -> String? {
    request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
        .queryItems?.first { $0.name == name }?.value
}

struct LibraryTests {
    @Test func moviesCarryTheirFileQualityAndHeadlineRating() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/movie", json: #"""
        [{"id": 2, "title": "Dune", "sortTitle": "dune", "year": 2021, "monitored": true, "hasFile": true,
          "sizeOnDisk": 5000000000, "added": "2024-05-01T12:00:00Z", "qualityProfileId": 4, "tmdbId": 438631,
          "imdbId": "tt1160419", "runtime": 155, "titleSlug": "dune-438631", "tags": [1], "genres": ["Science Fiction"],
          "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/dune.jpg"}],
          "ratings": {"imdb": {"value": 8.0}, "tmdb": {"value": 7.8}},
          "movieFile": {"quality": {"quality": {"name": "WEBDL-2160p"}}}},
         {"id": 1, "title": "Alien", "sortTitle": "alien", "runtime": 0, "ratings": {"tmdb": {"value": 7.1}}}]
        """#)
        let movies = try await direct.libraryMovies()
        #expect(movies.map(\.id) == [1, 2], "by Radarr's sort title")
        let dune = movies[1]
        #expect(dune.quality == "WEBDL-2160p")
        #expect(dune.rating == 8.0)
        #expect(dune.poster == "https://image.tmdb.org/t/p/w500/dune.jpg")
        #expect(dune.added != nil)
        #expect(dune.slug == "dune-438631")
        #expect(movies[0].rating == 7.1)
        #expect(movies[0].runtime == nil, "no runtime is none, not zero")
        #expect(movies[0].monitored == false)
        #expect(movies[0].tags == [])
    }

    @Test func aShowsNextEpisodeIsTheEarliestDatedOneAndPicksTheSeasonToTrack() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series", json: #"""
        [{"id": 1, "title": "Severance", "sortTitle": "severance", "status": "continuing", "network": "Apple TV+",
          "statistics": {"episodeCount": 19, "episodeFileCount": 11, "sizeOnDisk": 900},
          "ratings": {"votes": 12, "value": 8.7},
          "seasons": [{"seasonNumber": 0, "statistics": {"episodeFileCount": 1, "totalEpisodeCount": 4}},
                      {"seasonNumber": 3, "statistics": {"episodeFileCount": 3, "totalEpisodeCount": 10}},
                      {"seasonNumber": 4, "statistics": {"episodeFileCount": 0, "totalEpisodeCount": 8}}]},
         {"id": 2, "title": "Andor", "sortTitle": "andor",
          "seasons": [{"seasonNumber": 0, "statistics": {"episodeFileCount": 1, "totalEpisodeCount": 4}},
                      {"seasonNumber": 1, "statistics": {"episodeFileCount": 8, "totalEpisodeCount": 8}},
                      {"seasonNumber": 2, "statistics": {"episodeFileCount": 3, "totalEpisodeCount": 10}}]}]
        """#)
        transport.on("GET /api/v3/calendar", json: #"""
        [{"seriesId": 1, "seasonNumber": 3, "episodeNumber": 5, "airDateUtc": "2026-10-08T01:00:00Z"},
         {"seriesId": 1, "seasonNumber": 3, "episodeNumber": 4, "title": "Four", "airDateUtc": "2026-10-01T01:00:00Z",
          "finaleType": "midseason"},
         {"seriesId": 2, "seasonNumber": 3, "episodeNumber": 1, "airDateUtc": null}]
        """#)
        let series = try await direct.librarySeries()
        #expect(series.map(\.id) == [2, 1])
        let severance = series[1]
        #expect(severance.next_episode?.episode == 4)
        #expect(severance.next_episode?.title == "Four")
        #expect(severance.next_episode?.finale_type == "midseason")
        #expect(severance.current_season == SeasonProgress(have: 3, number: 3, total: 10), "the next episode's season")
        #expect(severance.rating == 8.7)
        #expect(severance.episode_file_count == 11)
        // an undated episode is no next episode; the latest real season then
        #expect(series[0].next_episode == nil)
        #expect(series[0].current_season == SeasonProgress(have: 3, number: 2, total: 10))
        let calendar = transport.requests.first { $0.url?.path().hasSuffix("/calendar") == true }
        #expect(query(calendar, "includeSeries") == "true")
    }

    @Test func aDeadCalendarStillListsTheShows() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series", json: #"[{"id": 1, "title": "Andor", "seasons": []}]"#)
        transport.on("GET /api/v3/calendar", status: 400, json: "")
        let series = try await direct.librarySeries()
        #expect(series.count == 1)
        #expect(series[0].next_episode == nil)
        #expect(series[0].current_season == nil)
    }

    @Test func theBookLibraryIsWhatWasAskedForOrIsOnDiskByAuthor() async throws {
        let (direct, transport) = backend(["readarr": .arr("http://10.0.0.5:8787")])
        transport.on("GET /api/v1/author", json: #"""
        [{"id": 7, "authorName": "Ursula K. Le Guin", "qualityProfileId": 2}, {"id": 8, "authorName": "Iain M. Banks"}]
        """#)
        transport.on("GET /api/v1/book", json: #"""
        [{"id": 1, "title": "The Dispossessed", "authorId": 7, "monitored": true, "releaseDate": "1974-05-01T00:00:00Z",
          "seriesTitle": "", "pageCount": 0, "ratings": {"value": 4.2},
          "images": [{"coverType": "cover", "url": "/MediaCover/1/cover.jpg"},
                     {"coverType": "cover", "remoteUrl": "https://images.example.com/dispossessed.jpg"}]},
         {"id": 2, "title": "Excession", "authorId": 8, "monitored": false, "statistics": {"bookFileCount": 1}},
         {"id": 3, "title": "Inversions", "authorId": 8, "monitored": false},
         {"id": 4, "title": "A Wizard of Earthsea", "authorId": 7, "monitored": true}]
        """#)
        let books = try await direct.libraryBooks()
        #expect(books.map(\.title) == ["Excession", "A Wizard of Earthsea", "The Dispossessed"],
                "unmonitored with nothing on disk is not in the library")
        let dispossessed = books[2]
        #expect(dispossessed.author == "Ursula K. Le Guin")
        #expect(dispossessed.quality_profile_id == 2, "the author's")
        #expect(dispossessed.year == 1974)
        #expect(dispossessed.series_title == nil)
        #expect(dispossessed.page_count == nil)
        #expect(dispossessed.poster == "https://images.example.com/dispossessed.jpg")
        #expect(books[0].has_file == true)
    }

    @Test func tagsAreSortedAndReadarrsAreNotAsked() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/tag", json: #"[{"id": 2, "label": "kids"}, {"id": 1, "label": "anime"}]"#)
        #expect(try await direct.tags(.sonarr).map(\.label) == ["anime", "kids"])
        await #expect(throws: APIError.refused("unknown app 'readarr'")) { try await direct.tags(.readarr) }
    }
}

struct SystemTests {
    @Test func aQualityProfileReadsBestFirstWithItsCutoffAndTheFormatsThatCount() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/qualityprofile", json: #"""
        [{"id": 1, "name": "HD", "upgradeAllowed": true, "cutoff": 1001, "minFormatScore": 10,
          "items": [{"quality": {"id": 1, "name": "SDTV"}, "allowed": false},
                    {"id": 1001, "name": "WEB 1080p", "allowed": true,
                     "items": [{"quality": {"id": 3, "name": "WEBDL-1080p"}}, {"quality": {"id": 15, "name": "WEBRip-1080p"}}]},
                    {"quality": {"id": 7, "name": "Bluray-1080p"}, "allowed": true}],
          "formatItems": [{"format": 5, "name": "x265", "score": -10}, {"format": 6, "score": 0}, {"format": 9, "score": 50}]}]
        """#)
        transport.on("GET /api/v3/customformat", json: #"[{"id": 9, "name": "IMAX"}, {"id": 5, "name": "x265 (HD)"}]"#)
        transport.on("GET /api/v3/qualitydefinition", status: 400, json: "")
        let result = try await direct.qualityProfiles(.radarr)
        let profile = try #require(result.profiles?.first)
        #expect(profile.cutoff == "WEB 1080p", "a group, matched as a group")
        #expect(profile.items?.map(\.name) == ["Bluray-1080p", "WEB 1080p", "SDTV"])
        #expect(profile.items?[1].is_group == true)
        #expect(profile.items?[1].is_cutoff == true)
        #expect(profile.items?[1].members == ["WEBDL-1080p", "WEBRip-1080p"])
        #expect(profile.format_scores?.map(\.name) == ["IMAX", "x265 (HD)"], "zero scores dropped, best first")
        #expect(profile.min_format_score == 10)
        #expect(result.custom_formats == ["IMAX", "x265 (HD)"])
        #expect(result.quality_definitions == [], "a failed size table is no table")
    }

    @Test func aTaskLateBeyondItsGraceIsOverdueAndADeadArrIsLeftOut() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878"), "sonarr": .arr()])
        let now = Date.now
        @Sendable func stamp(_ offset: TimeInterval) -> String { now.addingTimeInterval(offset).ISO8601Format() }
        transport.on("GET /api/v3/system/task") { request in
            guard request.url?.port == 7878 else { throw URLError(.cannotConnectToHost) }
            let json = """
            [{"name": "Rss Sync", "taskName": "RssSync", "interval": 15, "nextExecution": "\(stamp(-3600))",
              "lastExecution": "\(stamp(-4500))", "lastDuration": "00:00:01.5000000"},
             {"name": "Housekeeping", "taskName": "Housekeeping", "interval": 1440, "nextExecution": "\(stamp(-60))"},
             {"name": "Disabled", "taskName": "Disabled", "interval": 0, "nextExecution": "\(stamp(-99999))"}]
            """
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
        let block = try await direct.tasks()
        let tasks = try #require(block.value)
        #expect(block.staleAge == nil)
        #expect(tasks.map(\.name) == ["RssSync", "Disabled", "Housekeeping"], "overdue first, then the soonest")
        #expect(tasks[0].overdue == true)
        #expect(tasks[0].notable == true)
        #expect(tasks[0].label == "Rss Sync")
        #expect(tasks[0].last_duration_seconds == 1.5)
        #expect((tasks[0].overdue_by_seconds ?? 0) >= 3600)
        #expect(tasks[1].overdue == false, "an interval of 0 is disabled, not late")
        #expect(tasks[2].overdue == false, "a minute late on a daily task is within its grace")
        #expect(tasks.allSatisfy { $0.app == "radarr" })
    }

    @Test func backupsLinkOffTheArrsRootNewestFirst() async throws {
        let (direct, transport) = backend(["sonarr": .arr("http://10.0.0.5:8989/sonarr/")])
        transport.on("GET /api/v3/system/backup", json: #"""
        [{"name": "old.zip", "path": "/backup/scheduled/old.zip", "type": "scheduled", "size": 100, "time": "2026-10-01T00:00:00Z"},
         {"name": "new.zip", "path": "/backup/manual/new.zip", "type": "manual", "size": 200, "time": "2026-10-10T00:00:00Z"}]
        """#)
        let backups = try #require(try await direct.arrBackups().value)
        #expect(backups.map(\.name) == ["new.zip", "old.zip"])
        #expect(backups[0].url == "http://10.0.0.5:8989/sonarr/backup/manual/new.zip")
        #expect(backups[0].kind == "manual")
        #expect(backups[0].size_bytes == 200)
    }

    @Test func logsAskForTheLevelOnlyWhenOneIsChosen() async throws {
        let (direct, transport) = backend(["prowlarr": .arr("http://10.0.0.5:9696")])
        transport.on("GET /api/v1/log", json: #"""
        {"records": [{"time": "2026-10-10T00:00:00Z", "level": "error", "logger": "Indexer", "message": "Timed out",
                      "exception": "System.TimeoutException"}]}
        """#)
        let entries = try await direct.logs("prowlarr", level: "error")
        #expect(entries == [LogEntry(app: "prowlarr", exception: "System.TimeoutException", level: "error",
                                     logger: "Indexer", message: "Timed out", time: "2026-10-10T00:00:00Z")])
        #expect(query(transport.requests.last, "level") == "error")
        _ = try await direct.logs("prowlarr", level: "")
        #expect(query(transport.requests.last, "level") == nil)
    }

    @Test func anUpdateIsAvailableWhenTheLatestReleaseIsNotTheOneInstalled() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/system/status", json: #"{"version": "4.0.1"}"#)
        transport.on("GET /api/v3/update", json: #"""
        [{"version": "4.0.2", "latest": true, "installed": false}, {"version": "4.0.1", "installed": true}]
        """#)
        let status = try await direct.status()
        #expect(status.first?.update_available == "4.0.2")
    }
}

struct IndexerTests {
    private static let indexers = #"""
    [{"id": 3, "name": "Nyaa", "enable": false, "protocol": "torrent", "privacy": "public", "fields": []}]
    """#

    @Test func togglingSendsTheWholeIndexerBackFlipped() async throws {
        let (direct, transport) = backend(["prowlarr": .arr("http://10.0.0.5:9696")])
        transport.on("GET /api/v1/indexer", json: Self.indexers)
        transport.on("PUT /api/v1/indexer/3", json: "{}")
        #expect(try await direct.indexers() == [Indexer(enable: false, id: 3, name: "Nyaa", privacy: "public", _protocol: "torrent")])
        try await direct.toggleIndexer(3, enable: true)
        let sent = try body(transport.requests.last)
        #expect(sent["enable"] == true)
        #expect(sent["protocol"] == "torrent")
        await #expect(throws: APIError.refused("indexer not found")) { try await direct.testIndexer(99) }
    }

    @Test func aNewIndexerIsTheDefinitionFilledInNamedAndGivenAProfile() async throws {
        let (direct, transport) = backend(["prowlarr": .arr("http://10.0.0.5:9696")])
        transport.on("GET /api/v1/indexer/schema", json: #"""
        [{"name": "Nyaa", "protocol": "torrent", "privacy": "public", "appProfileId": 0,
          "fields": [{"name": "definitionFile", "value": "nyaa"},
                     {"name": "baseUrl", "label": "Base Url", "type": "select", "value": 0,
                      "selectOptions": [{"value": 0, "name": "https://nyaa.si/"}]},
                     {"name": "prefer_magnet", "type": "checkbox", "value": true},
                     {"name": "advanced_thing", "advanced": true},
                     {"name": "info_note", "type": "info"}]},
         {"name": "aniDub", "fields": []}]
        """#)
        transport.on("GET /api/v1/appprofile", json: #"[{"id": 2, "name": "Standard"}]"#)
        transport.on("POST /api/v1/indexer", json: #"{"id": 9}"#)
        let schemas = try await direct.indexerSchemas()
        #expect(schemas.map(\.name) == ["aniDub", "Nyaa"])
        let nyaa = schemas[1]
        #expect(nyaa.fields.map(\.name) == ["baseUrl", "prefer_magnet"], "hidden, advanced and the definition file left out")
        #expect(nyaa.fields[0].kind == .select)
        #expect(nyaa.fields[0].options == [IndexerField.Option(value: 0, name: "https://nyaa.si/")])
        #expect(nyaa.fields[1].defaultValue == .bool(true))

        try await direct.addIndexer(schema: "Nyaa", displayName: "  ", values: ["baseUrl": .number(1), "prefer_magnet": .bool(false)])
        let sent = try body(transport.requests.last)
        #expect(sent["name"] == "Nyaa", "a blank name is the definition's")
        #expect(sent["enable"] == true)
        #expect(sent["appProfileId"] == 2)
        let fields = sent["fields"].array
        #expect(fields.first { $0["name"] == "baseUrl" }?["value"] == 1)
        #expect(fields.first { $0["name"] == "prefer_magnet" }?["value"] == false)
        #expect(fields.first { $0["name"] == "definitionFile" }?["value"] == "nyaa", "kept as Prowlarr sent it")
    }
}

struct SearchTests {
    @Test func aMovieSearchSaysWhatTheLibraryHas() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/movie/lookup", json: #"""
        [{"title": "Dune", "year": 2021, "tmdbId": 438631, "imdbId": "tt1160419",
          "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/dune.jpg"}]},
         {"title": "Dune", "year": 1984, "tmdbId": 841}]
        """#)
        transport.on("GET /api/v3/movie", json: #"""
        [{"id": 12, "tmdbId": 438631, "monitored": true, "qualityProfileId": 4, "hasFile": true}]
        """#)
        let results = try await direct.search(.movies, query: "dune")
        #expect(results.count == 2)
        #expect(results[0].in_library == true)
        #expect(results[0].library_id == 12)
        #expect(results[0].quality_profile_id == 4)
        #expect(results[0].has_file == true)
        #expect(results[0].ref == .movie(12))
        #expect(results[0].poster == "https://image.tmdb.org/t/p/w500/dune.jpg")
        #expect(results[1].in_library == false)
        #expect(results[1].library_id == nil)
        #expect(results[1].remote_id == 841)
        #expect(query(transport.requests.first, "term") == "dune")
    }

    @Test func discoverKeepsWesternTitlesOnceWithServerSizedPosters() async throws {
        let (direct, transport) = backend(["overseerr": .arr("http://10.0.0.5:5055"), "radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v1/discover/movies") { request in
            let page = query(request, "page")
            let json = page == "1"
                ? #"""
                {"results": [{"id": 1, "title": "Anora", "releaseDate": "2024-10-18", "posterPath": "/anora.jpg", "originalLanguage": "en"},
                             {"id": 2, "title": "RRR", "originalLanguage": "te"},
                             {"id": 3, "title": "Flow", "originalLanguage": "lv"},
                             {"id": 4, "title": "Druk", "originalLanguage": "da"}]}
                """#
                : page == "2" ? #"{"results": [{"id": 1, "title": "Anora", "originalLanguage": "en"}, {"id": 5, "title": "Untitled"}]}"#
                : #"{"results": []}"#
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
        transport.on("GET /api/v3/movie", json: #"[{"id": 40, "tmdbId": 4, "monitored": false}]"#)
        let found = try await direct.discover(.movies)
        #expect(found.map(\.title) == ["Anora", "Druk", "Untitled"], "western languages, each once; none said is English")
        #expect(found[0].poster == "https://image.tmdb.org/t/p/w500/anora.jpg")
        #expect(found[0].year == 2024)
        #expect(found[0].tmdb_id == 1)
        #expect(found[1].in_library == true)
        #expect(found[1].monitored == false)
        #expect(try await direct.discover(.books) == [])
    }

    @Test func discoveredShowsResolveToTheirTvdbIdOrAreDropped() async throws {
        let (direct, transport) = backend(["overseerr": .arr("http://10.0.0.5:5055"), "sonarr": .arr()])
        transport.on("GET /api/v1/discover/tv") { request in
            let json = query(request, "page") == "1"
                ? #"{"results": [{"id": 10, "name": "Shogun", "firstAirDate": "2024-02-27"}, {"id": 11, "name": "Nobody"}]}"#
                : #"{"results": []}"#
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
        transport.on("GET /api/v1/tv/10", json: #"{"externalIds": {"tvdbId": 389396, "imdbId": "tt2788316"}}"#)
        transport.on("GET /api/v1/tv/11", json: #"{"externalIds": {}}"#)
        transport.on("GET /api/v3/series", json: "[]")
        let found = try await direct.discover(.series)
        #expect(found.count == 1)
        #expect(found[0].remote_id == 389396)
        #expect(found[0].imdb_id == "tt2788316")
        #expect(found[0].tmdb_id == 10)
        #expect(found[0].year == 2024)
    }

    @Test func aCollectionCountsWhatIsMissing() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/collection", json: #"""
        [{"id": 2, "title": "the Matrix Collection", "monitored": true, "movies": [{"tmdbId": 603}, {"tmdbId": 604}, {"tmdbId": 605}]},
         {"id": 1, "title": "Alien Collection", "movies": [{"tmdbId": 348, "title": "Alien"}]}]
        """#)
        transport.on("GET /api/v3/movie", json: #"[{"id": 1, "tmdbId": 603}, {"id": 5, "tmdbId": 348}]"#)
        transport.on("PUT /api/v3/collection/1", json: "{}")
        let all = try await direct.collections()
        #expect(all.map(\.id) == [1, 2])
        #expect(all[1].movie_count == 3)
        #expect(all[1].missing_count == 2)
        let alien = try await direct.collectionDetail(1)
        #expect(alien.movies?.first?.library_id == 5)
        try await direct.setCollectionMonitored(1, true)
        #expect(try body(transport.requests.last)["monitored"] == true)
        await #expect(throws: APIError.refused("collection not found")) { try await direct.collectionDetail(9) }
    }
}

struct AddTests {
    @Test func aMovieIsAddedMonitoredAndSearchedAndTheBadgeReadsAfresh() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/movie/lookup", json: #"[{"title": "Dune", "tmdbId": 438631}]"#)
        transport.on("GET /api/v3/movie", json: "[]")
        transport.on("POST /api/v3/movie", json: #"{"id": 12}"#)
        let result = try #require(try await direct.search(.movies, query: "dune").first)
        try await direct.add(result, qualityProfile: 4, rootFolder: "/movies", metadataProfile: nil, edition: nil)
        let sent = try body(transport.requests.last)
        #expect(sent == ["tmdbId": 438631, "title": "Dune", "qualityProfileId": 4, "rootFolderPath": "/movies",
                         "monitored": true, "addOptions": ["searchForMovie": true]])
        transport.on("GET /api/v3/movie", json: #"[{"id": 12, "tmdbId": 438631}]"#)
        #expect(try await direct.search(.movies, query: "dune").first?.in_library == true)
    }

    @Test func aBookWithANewAuthorBringsThemMonitoringJustThatBook() async throws {
        let (direct, transport) = backend(["readarr": .arr("http://10.0.0.5:8787")])
        transport.on("GET /api/v1/search", json: #"""
        [{"author": {"authorName": "Ursula K. Le Guin"}},
         {"book": {"title": "The Dispossessed", "foreignBookId": "13651", "releaseDate": "1974-05-01T00:00:00Z",
                   "remoteCover": "https://images.example.com/d.jpg", "author": {"authorName": "Ursula K. Le Guin"},
                   "editions": [{"foreignEditionId": "e1", "title": "The Dispossessed", "monitored": true, "format": "Paperback"},
                                {"foreignEditionId": "e2", "title": "Les Dépossédés", "language": "fre"}]}}]
        """#)
        transport.on("GET /api/v1/book", json: "[]")
        transport.on("GET /api/v1/metadataprofile", json: #"[{"id": 3, "name": "Standard"}]"#)
        transport.on("POST /api/v1/book", json: #"{"id": 1}"#)
        let results = try await direct.search(.books, query: "dispossessed")
        let book = try #require(results.first)
        #expect(results.count == 1, "an author entry is no result")
        #expect(book.remote_id == 13651)
        #expect(book.foreign_edition_id == "e1", "the monitored edition")
        #expect(book.editions?.map(\.foreign_edition_id) == ["e1", "e2"])
        #expect(book.year == 1974)

        try await direct.add(book, qualityProfile: 1, rootFolder: "/books", metadataProfile: nil, edition: "e2")
        #expect(query(transport.requests.first { $0.httpMethod == "GET" && query($0, "term") == "edition:e2" }, "term") == "edition:e2")
        let sent = try body(transport.requests.last)
        #expect(sent["author"]["metadataProfileId"] == 3, "Readarr's first, for a new author")
        #expect(sent["author"]["qualityProfileId"] == 1)
        #expect(sent["author"]["monitorNewItems"] == "none")
        #expect(sent["author"]["addOptions"]["booksToMonitor"] == ["13651"])
        #expect(sent["editions"].array.map { $0["monitored"] } == [false, true], "the picked edition is the monitored one")
        #expect(sent["foreignEditionId"] == "e2")
        #expect(sent["addOptions"] == ["searchForNewBook": true])
    }

    @Test func anAlbumWithoutItsArtistBringsThemMonitoringOnlyThatAlbum() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/album/lookup", json: #"""
        [{"title": "Geogaddi", "foreignAlbumId": "abc", "artist": {"artistName": "Boards of Canada", "foreignArtistId": "boc"}}]
        """#)
        transport.on("POST /api/v1/album", json: #"{"id": 1}"#)
        let album = SearchResult(foreign_id: "abc", kind: "album", remote_id: 0, title: "Geogaddi")
        try await direct.add(album, qualityProfile: 1, rootFolder: "/music", metadataProfile: 2, edition: nil)
        let sent = try body(transport.requests.last)
        #expect(query(transport.requests.first, "term") == "lidarr:abc")
        #expect(sent["monitored"] == true)
        #expect(sent["addOptions"] == ["searchForNewAlbum": true])
        #expect(sent["artist"]["metadataProfileId"] == 2)
        #expect(sent["artist"]["monitorNewItems"] == "none")
        #expect(sent["artist"]["tags"] == [])
        #expect(sent["artist"]["addOptions"] == ["monitor": "all", "albumsToMonitor": ["abc"], "monitored": true,
                                                 "searchForMissingAlbums": false])
    }

    @Test func anArtistFromSearchMonitorsEveryAlbumAndSearches() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/artist/lookup", json: #"[{"artistName": "Boards of Canada", "foreignArtistId": "boc", "tags": [3]}]"#)
        transport.on("GET /api/v1/metadataprofile", json: #"[{"id": 5}]"#)
        transport.on("POST /api/v1/artist", json: #"{"id": 1}"#)
        let artist = SearchResult(foreign_id: "boc", kind: "artist", remote_id: 0, title: "Boards of Canada")
        try await direct.add(artist, qualityProfile: 1, rootFolder: "/music", metadataProfile: nil, edition: nil)
        let sent = try body(transport.requests.last)
        #expect(sent["metadataProfileId"] == 5)
        #expect(sent["monitorNewItems"] == "all")
        #expect(sent["tags"] == [3])
        #expect(sent["addOptions"] == ["monitor": "all", "monitored": true, "searchForMissingAlbums": true])
    }
}

struct MusicTests {
    @Test func musicSearchBadgesArtistsAndAlbumsByTheirMusicBrainzID() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/search", json: #"""
        [{"artist": {"artistName": "Boards of Canada", "foreignArtistId": "boc", "images": []}},
         {"album": {"title": "Geogaddi", "foreignAlbumId": "abc", "albumType": "Album", "releaseDate": "2002-02-18T00:00:00Z",
                    "artist": {"artistName": "Boards of Canada"}, "remoteCover": "https://images.lidarr.audio/geogaddi.jpg"}},
         {"something": {}}]
        """#)
        transport.on("GET /api/v1/artist", json: #"""
        [{"id": 4, "artistName": "Boards of Canada", "foreignArtistId": "boc", "monitored": true, "qualityProfileId": 2,
          "statistics": {"trackFileCount": 3}, "images": [{"coverType": "poster", "url": "/MediaCover/4/poster.jpg"}]}]
        """#)
        transport.on("GET /api/v1/album", json: "[]")
        let results = try await direct.search(.music, query: "boards")
        #expect(results.map(\.kind) == ["artist", "album"])
        #expect(results[0].in_library == true)
        #expect(results[0].library_id == 4)
        #expect(results[0].quality_profile_id == 2)
        #expect(results[0].poster == "http://10.0.0.5:8686/api/v1/mediacover/artist/4/poster-250.jpg?apikey=secret",
                "the library's own picture when the search has none")
        #expect(results[1].in_library == false)
        #expect(results[1].year == 2002)
        #expect(results[1].album_type == "Album")
        #expect(results[1].poster == "https://images.lidarr.audio/geogaddi.jpg")
    }

    @Test func artistsAreListedBySortName() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/artist", json: #"""
        [{"id": 1, "artistName": "The Beatles", "sortName": "beatles, the",
          "statistics": {"albumCount": 13, "trackFileCount": 0, "totalTrackCount": 0, "trackCount": 213}},
         {"id": 2, "artistName": "Autechre", "sortName": "", "ratings": {"value": 8, "votes": 0}}]
        """#)
        let artists = try await direct.libraryArtists()
        #expect(artists.map(\.id) == [2, 1])
        #expect(artists[1].track_count == 213, "the total, or the count when there is none")
        #expect(artists[0].rating == nil, "a score without votes is none")
    }

    @Test func anAlbumsTracksAndOneEventPerDownload() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/album/7", json: #"""
        {"id": 7, "title": "Geogaddi", "artistId": 4, "duration": 3975500, "releaseDate": "2002-02-18T00:00:00Z",
         "artist": {"artistName": "Boards of Canada", "qualityProfileId": 2, "foreignArtistId": "boc"},
         "statistics": {"trackFileCount": 1, "sizeOnDisk": 10},
         "releases": [{"format": "CD", "label": ["Warp"], "monitored": false, "media": []},
                      {"format": "2x12\" Vinyl", "label": ["Warp", "Music70"], "monitored": true,
                       "media": [{"mediumNumber": 1, "mediumFormat": "Vinyl", "mediumName": ""}]}]}
        """#)
        transport.on("GET /api/v1/track", json: #"""
        [{"id": 2, "mediumNumber": 1, "absoluteTrackNumber": 2, "trackNumber": "A2", "title": "Music Is Math",
          "duration": 321500, "hasFile": false, "trackFileId": 0},
         {"id": 1, "mediumNumber": 1, "absoluteTrackNumber": 1, "trackNumber": "A1", "title": "Ready Lets Go",
          "duration": 60000, "hasFile": true, "trackFileId": 30}]
        """#)
        transport.on("GET /api/v1/trackfile", json: #"[{"id": 30, "size": 1234, "quality": {"quality": {"name": "FLAC"}}}]"#)
        transport.on("GET /api/v1/history", json: #"""
        {"records": [{"eventType": "trackFileImported", "downloadId": "d1", "date": "2026-10-10T10:00:01Z"},
                     {"eventType": "trackFileImported", "downloadId": "d1", "date": "2026-10-10T10:00:02Z"},
                     {"eventType": "grabbed", "downloadId": "d1", "date": "2026-10-10T09:00:00Z"}]}
        """#)
        let album = try await direct.albumDetail(7)
        #expect(album.release == "2x12\" Vinyl · Warp, Music70", "the monitored release")
        #expect(album.media == [AlbumMedium(format: "Vinyl", name: nil, number: 1)])
        #expect(album.track_count == 2, "no count from Lidarr: the tracks")
        #expect(album.duration == 3976)
        #expect(album.tracks?.map(\.number) == ["A1", "A2"])
        #expect(album.tracks?[0].quality == "FLAC")
        #expect(album.tracks?[0].file_id == 30)
        #expect(album.tracks?[1].duration == 322, "rounded half to even, as Python does")
        #expect(album.history?.map(\._type) == ["imported", "fetched"])
        #expect(album.quality_profile_id == 2)
    }

    @Test func aTrackFileMustBelongToTheAlbum() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/trackfile", json: #"[{"id": 30}, {"id": 31}]"#)
        transport.on("DELETE /api/v1/trackfile/bulk", json: "")
        await #expect(throws: APIError.refused("no such file on this album")) {
            try await direct.deleteAlbumFiles(album: 7, file: 99)
        }
        try await direct.deleteAlbumFiles(album: 7, file: nil)
        #expect(try body(transport.requests.last) == ["trackFileIds": [30, 31]])
    }

    @Test func aMovedFolderMustBeAbsolute() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/artist/4", json: #"{"id": 4, "path": "/music/BoC", "monitored": false}"#)
        transport.on("PUT /api/v1/artist/4", json: #"{"id": 4}"#)
        await #expect(throws: APIError.refused("path must be absolute")) {
            try await direct.updateArtist(4, ArtistChanges(path: "music/BoC"))
        }
        try await direct.updateArtist(4, ArtistChanges(monitored: true, path: " /music/Boards ", moveFiles: true))
        let put = transport.requests.last
        #expect(query(put, "moveFiles") == "true")
        #expect(try body(put)["path"] == "/music/Boards")
        #expect(try body(put)["monitored"] == true)
    }
}

struct PopularTests {
    @Test func theDaysReleasesRankByGrabsPerIndexerEachOnce() async throws {
        let (direct, transport) = backend(["prowlarr": .arr("http://10.0.0.5:9696")])
        transport.on("GET /api/v1/indexer", json: #"""
        [{"id": 1, "name": "Tracker", "enable": true,
          "capabilities": {"categories": [{"id": 2000, "subCategories": [{"id": 2040}, {"id": 2045}]},
                                          {"id": 5000, "subCategories": []}, {"id": 3000}]}},
         {"id": 2, "name": "Off", "enable": false}]
        """#)
        let fresh = Date.now.addingTimeInterval(-3600).ISO8601Format()
        let old = Date.now.addingTimeInterval(-3 * 86400).ISO8601Format()
        transport.on("GET /api/v1/search") { request in
            let json = switch query(request, "categories") {
            case "2040": """
                [{"guid": "a", "downloadUrl": "u-a", "title": "Film A", "grabs": 5, "seeders": 1, "publishDate": "\(fresh)",
                  "indexerId": 1, "categories": [{"id": 2040, "name": "Movies/HD"}]},
                 {"guid": "old", "title": "Old", "grabs": 99, "publishDate": "\(old)"}]
                """
            case "2045": """
                [{"guid": "a", "downloadUrl": "u-a", "title": "Film A", "grabs": 5, "publishDate": "\(fresh)"},
                 {"guid": "b", "title": "Film B", "grabs": 9, "publishDate": "\(fresh)", "categories": [{"id": 2045}]}]
                """
            case "5000": """
                [{"guid": "c", "title": "Show C", "grabs": 5, "seeders": 7, "publishDate": "\(fresh)",
                  "categories": [{"id": 5040, "name": "TV/HD"}]}]
                """
            default: "[]"
            }
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
        let block = try await direct.popular(hours: 24, limit: 2)
        let snapshot = try #require(block.value)
        #expect(snapshot.hours == 24)
        let indexer = try #require(snapshot.indexers?.first)
        #expect(snapshot.indexers?.count == 1, "enabled indexers only")
        #expect(indexer.scanned == 3, "inside the window, each once")
        #expect(indexer.releases?.map(\.guid) == ["b", "c"], "most grabbed, then most seeded; sliced to the limit")
        #expect(indexer.releases?.map(\.kind) == ["movie", "tv"])
        #expect(indexer.releases?[1].category == "TV/HD")
        let searches = transport.requests.filter { $0.url?.path().hasSuffix("/search") == true }
        #expect(Set(searches.compactMap { query($0, "categories") }) == ["2040", "2045", "5000"])
        #expect(searches.allSatisfy { query($0, "indexerIds") == "1" && query($0, "limit") == "100" })

        // the day's snapshot is kept: a wider slice comes from it, not the trackers
        let count = transport.requests.count
        #expect(try await direct.popular(hours: 24, limit: 10).value?.indexers?.first?.releases?.count == 3)
        #expect(transport.requests.count == count)
    }

    @Test func withoutProwlarrThePageSaysSo() async throws {
        let (direct, _) = backend([:])
        #expect(try await direct.popular(hours: 24, limit: 10) == .offline("not configured"))
    }
}
