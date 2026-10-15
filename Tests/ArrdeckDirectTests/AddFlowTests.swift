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

private func sent(_ transport: StubTransport, _ method: String, _ suffix: String) -> [URLRequest] {
    transport.requests.filter { $0.httpMethod == method && $0.url?.path().hasSuffix(suffix) == true }
}

private let reacher = SearchResult(kind: "series", remote_id: 1, title: "Reacher")

struct AddFlowSeriesTests {
    @Test func seasonsComeFromTheLookupMatchingTheShowSortedOnce() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series/lookup", json: #"""
        [{"tvdbId": 9, "seasons": [{"seasonNumber": 7}]},
         {"tvdbId": 1, "seasons": [{"seasonNumber": 2}, {"seasonNumber": 0}, {"seasonNumber": 1}, {"seasonNumber": 2}, {}]}]
        """#)
        #expect(try await direct.seriesSeasons(tvdbID: 1) == [0, 1, 2])
        #expect(query(transport.requests.last, "term") == "tvdb:1")
    }

    @Test func pickedSeasonsAreSentAsSonarrsOwnListAndSkip() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series/lookup", json: #"""
        [{"tvdbId": 1, "seasons": [{"seasonNumber": 0}, {"seasonNumber": 1}, {"seasonNumber": 2}, {"seasonNumber": 3}, {"seasonNumber": 4}]}]
        """#)
        transport.on("POST /api/v3/series", json: #"{"id": 5, "title": "Reacher"}"#)
        direct.cache.set("library_map:series", [Int: Catalog.Held]())
        // a preset sent alongside a pick is ignored
        try await direct.addSeries(reacher, qualityProfile: 4, rootFolder: "/tv", monitor: .all, seasons: [3, 4])
        let payload = try body(sent(transport, "POST", "/api/v3/series").last)
        #expect(payload["seasons"] == [
            ["seasonNumber": 0, "monitored": false], ["seasonNumber": 1, "monitored": false],
            ["seasonNumber": 2, "monitored": false], ["seasonNumber": 3, "monitored": true],
            ["seasonNumber": 4, "monitored": true],
        ])
        #expect(payload["addOptions"] == ["searchForMissingEpisodes": true, "monitor": "skip"])
        #expect(payload["tvdbId"] == 1 && payload["qualityProfileId"] == 4 && payload["rootFolderPath"] == "/tv")
        #expect(payload["monitored"] == true && payload["seasonFolder"] == true)
        let forgotten: [Int: Catalog.Held]? = direct.cache.fresh("library_map:series", ttl: 60)
        #expect(forgotten == nil, "the in-library badges read afresh")

        try await direct.addSeries(reacher, qualityProfile: 4, rootFolder: "/tv", monitor: .pick, seasons: [])
        let none = try body(sent(transport, "POST", "/api/v3/series").last)
        #expect(none["addOptions"]["searchForMissingEpisodes"] == false, "nothing picked, nothing to search for")
    }

    @Test func aPresetGoesThroughAsSonarrsMonitorOptionWithoutALookup() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("POST /api/v3/series", json: #"{"id": 5}"#)
        try await direct.addSeries(reacher, qualityProfile: 4, rootFolder: "/tv", monitor: .lastSeason, seasons: nil)
        let preset = try body(sent(transport, "POST", "/api/v3/series").last)
        #expect(preset["addOptions"] == ["searchForMissingEpisodes": true, "monitor": "lastSeason"])
        #expect(preset["seasons"] == .null)
        #expect(sent(transport, "GET", "/series/lookup").isEmpty)

        try await direct.addSeries(reacher, qualityProfile: 4, rootFolder: "/tv", monitor: .none, seasons: nil)
        let none = try body(sent(transport, "POST", "/api/v3/series").last)
        #expect(none["addOptions"] == ["searchForMissingEpisodes": false, "monitor": "none"])
    }

    @Test func aRefusedAddSaysWhy() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("POST /api/v3/series", status: 400, json: #"[{"errorMessage": "This series has already been added"}]"#)
        await #expect(throws: APIError.self) {
            try await direct.addSeries(reacher, qualityProfile: 4, rootFolder: "/tv", monitor: .all, seasons: nil)
        }
    }
}

struct AddFlowMusicTests {
    @Test func anArtistIsAddedWithTheChosenAlbumsMonitored() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/artist/lookup", json: #"[{"foreignArtistId": "mb-1", "artistName": "Björk"}]"#)
        transport.on("POST /api/v1/artist", json: #"{"id": 3}"#)
        let artist = SearchResult(foreign_id: "mb-1", kind: "artist", remote_id: 0, title: "Björk")
        try await direct.addArtist(artist, qualityProfile: 1, rootFolder: "/music", metadataProfile: 2, monitor: .latest)
        let payload = try body(sent(transport, "POST", "/api/v1/artist").last)
        #expect(payload["addOptions"]["monitor"] == "latest")
        #expect(payload["addOptions"]["searchForMissingAlbums"] == true)
        #expect(payload["metadataProfileId"] == 2)

        try await direct.addArtist(artist, qualityProfile: 1, rootFolder: "/music", metadataProfile: 2, monitor: .none)
        let none = try body(sent(transport, "POST", "/api/v1/artist").last)
        #expect(none["addOptions"]["searchForMissingAlbums"] == false, "monitoring nothing searches for nothing")
    }

    @Test func anAlbumWithoutItsArtistBringsThemAlong() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("GET /api/v1/album/lookup", json: #"""
        [{"foreignAlbumId": "al-1", "title": "Homogenic", "artist": {"foreignArtistId": "mb-1", "artistName": "Björk"}}]
        """#)
        transport.on("POST /api/v1/album", json: #"{"id": 8}"#)
        let album = SearchResult(foreign_id: "al-1", kind: "album", remote_id: 0, title: "Homogenic")
        try await direct.addAlbum(album, qualityProfile: 1, rootFolder: "/music", metadataProfile: 2)
        let payload = try body(sent(transport, "POST", "/api/v1/album").last)
        #expect(payload["artist"]["addOptions"]["albumsToMonitor"] == ["al-1"])
        #expect(payload["addOptions"] == ["searchForNewAlbum": true])
    }
}

struct AddFlowQueueTests {
    @Test func grabNowAsksTheArrToSendTheHeldRelease() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("POST /api/v1/queue/grab/7", status: 200, json: "")
        try await direct.grabNow(app: .lidarr, id: 7)
        #expect(sent(transport, "POST", "/api/v1/queue/grab/7").count == 1)
    }
}

struct AddFlowRecommendationTests {
    static let items = #"""
    [{"tmdbId": 1, "title": "Owned", "isRecommendation": true, "isExisting": true, "popularity": 90},
     {"tmdbId": 2, "title": "Skipped", "isRecommendation": true, "isExcluded": true, "popularity": 80},
     {"tmdbId": 3, "title": "Quiet", "isRecommendation": true, "popularity": 5,
      "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/q.jpg"}]},
     {"tmdbId": 4, "title": "Loud", "isRecommendation": true, "popularity": 50, "year": 2024, "imdbId": "tt4",
      "remotePoster": "https://image.tmdb.org/t/p/original/x.jpg"},
     {"tmdbId": 5, "title": "Trending, not recommended", "isTrending": true},
     {"tmdbId": 0, "title": "No id", "isRecommendation": true}]
    """#

    @Test func radarrsSuggestionsMinusHeldAndSkippedBestKnownFirst() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/importlist/movie", json: Self.items)
        let rows = try await direct.recommendations()
        #expect(rows.map(\.title) == ["Loud", "Quiet"])
        #expect(rows[0].kind == "movie" && rows[0].remote_id == 4 && rows[0].tmdb_id == 4 && rows[0].imdb_id == "tt4")
        #expect(rows[0].poster == "https://image.tmdb.org/t/p/w500/x.jpg")
        #expect(rows[1].poster == "https://image.tmdb.org/t/p/w500/q.jpg")
        #expect(rows[0].year == 2024 && rows[1].year == nil)
        #expect(rows.allSatisfy { $0.in_library == false && $0.editions == [] })
        let request = transport.requests.last
        #expect(query(request, "includeRecommendations") == "true")
        #expect(query(request, "includeTrending") == "false" && query(request, "includePopular") == "false")
    }

    @Test func dismissingExcludesTheFilmAndDropsItWithoutAskingAgain() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/importlist/movie", json: Self.items)
        transport.on("POST /api/v3/exclusions", json: #"{"id": 1}"#)
        _ = try await direct.recommendations()
        try await direct.dismissRecommendation(3)
        let exclusion = try body(sent(transport, "POST", "/exclusions").last)
        #expect(exclusion == ["tmdbId": 3, "movieTitle": "Quiet", "movieYear": 0])
        #expect(try await direct.recommendations().map(\.title) == ["Loud"])
        #expect(sent(transport, "GET", "/importlist/movie").count == 1)

        try await direct.dismissRecommendation(99)
        #expect(try body(sent(transport, "POST", "/exclusions").last)["movieTitle"] == "99", "an unknown film by its id")
    }
}

struct AddFlowPeopleTests {
    static func stub(_ transport: StubTransport) {
        transport.on("GET /api/v3/movie", json: #"""
        [{"id": 1, "title": "Lady Bird", "year": 2017, "tmdbId": 391713, "hasFile": true, "monitored": true,
          "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/lb.jpg"}]},
         {"id": 2, "title": "Barbie", "year": 2023, "tmdbId": 346698}]
        """#)
        transport.on("GET /api/v3/credit") { request in
            let json = switch query(request, "movieId") {
            case "1": #"[{"movieMetadataId": 10}]"#
            case "2": #"[{"movieMetadataId": 20}]"#
            default: #"""
                [{"personTmdbId": 7, "personName": "Greta", "movieMetadataId": 10, "type": "crew", "job": "Director"},
                 {"personTmdbId": 7, "personName": "Greta", "movieMetadataId": 10, "type": "crew", "job": "Writer"},
                 {"personTmdbId": 7, "personName": "Greta", "movieMetadataId": 20, "type": "cast", "character": "Herself"},
                 {"personTmdbId": 8, "movieMetadataId": 99, "type": "cast"}]
                """#
            }
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
    }

    @Test func theirLibraryFilmsNewestFirstWithOneRoleEach() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        Self.stub(transport)
        let person = try await direct.person(7)
        #expect(person.tmdb_id == 7 && person.name == "Greta")
        #expect(person.owned?.map(\.movie_id) == [2, 1], "newest first")
        #expect(person.owned?.map(\.role) == ["Herself", "Director"])
        let ladyBird = try #require(person.owned?.last)
        #expect(ladyBird.has_file == true && ladyBird.monitored == true && ladyBird.year == 2017)
        #expect(ladyBird.poster == "https://image.tmdb.org/t/p/w500/lb.jpg")
        #expect(person.owned?.first?.has_file == false)
        #expect(person.elsewhere == [] && person.image == nil, "no Overseerr, no rest of the filmography")

        // the index is rebuilt, but films already mapped are not asked about again
        let asked = transport.requests.filter { query($0, "movieId") != nil }.count
        #expect(asked == 2)
        direct.cache.remove(["people:index"])
        _ = try await direct.person(7)
        #expect(transport.requests.filter { query($0, "movieId") != nil }.count == asked)
    }

    @Test func noOneByThatIDIsNotFound() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        Self.stub(transport)
        await #expect(throws: APIError.unexpectedStatus(404)) { try await direct.person(42) }
    }

    @Test func overseerrAddsTheirPictureAndReleasedFilmsNotInTheLibrary() async throws {
        let (direct, transport) = backend([
            "radarr": .arr("http://10.0.0.5:7878"), "overseerr": .arr("http://10.0.0.6:5055"),
        ])
        Self.stub(transport)
        transport.on("GET /api/v1/person/7", json: #"""
        {"name": "Greta Gerwig", "profilePath": "/g.jpg", "knownForDepartment": "Directing"}
        """#)
        transport.on("GET /api/v1/person/7/combined_credits", json: #"""
        {"cast": [{"id": 391713, "mediaType": "movie", "title": "Lady Bird", "releaseDate": "2017-11-03", "popularity": 90},
                  {"id": 3, "mediaType": "tv", "name": "A show", "popularity": 50},
                  {"id": 4, "mediaType": "movie", "title": "Announced", "popularity": 30},
                  {"id": 6, "mediaType": "movie", "title": "Far off", "releaseDate": "2999-01-01", "popularity": 40},
                  {"id": 2, "mediaType": "movie", "title": "Less known", "releaseDate": "2019-01-01", "popularity": 1}],
         "crew": [{"id": 5, "mediaType": "movie", "title": "Famous", "releaseDate": "2021-05-01", "popularity": 20,
                   "posterPath": "/f.jpg", "overview": "Big."},
                  {"id": 5, "mediaType": "movie", "title": "Famous", "releaseDate": "2021-05-01", "popularity": 20}]}
        """#)
        let person = try await direct.person(7)
        #expect(person.name == "Greta Gerwig" && person.known_for == "Directing")
        #expect(person.image == "https://image.tmdb.org/t/p/w185/g.jpg")
        let elsewhere = try #require(person.elsewhere)
        #expect(elsewhere.map(\.title) == ["Famous", "Less known"])
        #expect(elsewhere[0].remote_id == 5 && elsewhere[0].tmdb_id == 5 && elsewhere[0].year == 2021)
        #expect(elsewhere[0].poster == "https://image.tmdb.org/t/p/w500/f.jpg" && elsewhere[0].in_library == false)

        // someone only Overseerr knows still has a page
        transport.on("GET /api/v1/person/42", json: #"{"name": "Noah Baumbach"}"#)
        transport.on("GET /api/v1/person/42/combined_credits", json: #"{"cast": [], "crew": []}"#)
        let stranger = try await direct.person(42)
        #expect(stranger.name == "Noah Baumbach" && stranger.owned == [])
    }

    @Test func aDeadOverseerrLeavesTheLibraryHalf() async throws {
        let (direct, transport) = backend([
            "radarr": .arr("http://10.0.0.5:7878"), "overseerr": .arr("http://10.0.0.6:5055"),
        ])
        Self.stub(transport)
        let person = try await direct.person(7)
        #expect(person.name == "Greta" && person.owned?.count == 2 && person.elsewhere == [])
    }

    @Test func todayIsTheDevicesOwnDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        // 23:30 UTC on 22 September is already the 23rd in Copenhagen
        #expect(People.todayISO(Date(timeIntervalSince1970: 1_790_119_800), calendar: calendar) == "2026-09-23")
    }
}

struct AddFlowTraktTests {
    static let trending = #"""
    [{"watchers": 9, "show": {"title": "Slow Horses", "year": 2022, "overview": "Spies.",
                              "ids": {"tvdb": 372264, "tmdb": 95480, "imdb": "tt5875444"}}},
     {"watchers": 4, "show": {"title": "No tvdb", "ids": {"tmdb": 1}}},
     {"watchers": 2, "show": {"title": "Andor", "year": 0, "ids": {"tvdb": 393189}}}]
    """#

    @Test func aListOfShowsKeyedByTVDBWithPostersAndLibraryBadges() async throws {
        let (direct, transport) = backend(["trakt": ServiceConnection(apiKey: "cid"), "sonarr": .arr()])
        transport.on("GET /shows/trending", json: Self.trending)
        transport.on("GET /api/v3/series", json: #"""
        [{"id": 11, "tvdbId": 393189, "monitored": true, "qualityProfileId": 2,
          "statistics": {"episodeCount": 12, "percentOfEpisodes": 100}}]
        """#)
        transport.on("GET /api/v3/series/lookup") { request in
            let json = query(request, "term") == "tvdb:372264"
                ? #"[{"remotePoster": "https://image.tmdb.org/t/p/original/sh.jpg"}]"#
                : "[]"
            return ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
        }
        let rows = try await direct.traktList(movies: false, list: .trending)
        #expect(rows.map(\.title) == ["Slow Horses", "Andor"])
        let slow = rows[0]
        #expect(slow.kind == "series" && slow.remote_id == 372264 && slow.tmdb_id == 95480 && slow.imdb_id == "tt5875444")
        #expect(slow.poster == "https://image.tmdb.org/t/p/w500/sh.jpg" && slow.year == 2022)
        #expect(slow.in_library == false)
        let andor = rows[1]
        #expect(andor.poster == nil && andor.year == nil)
        #expect(andor.in_library == true && andor.library_id == 11 && andor.has_file == true)

        let list = try #require(transport.requests.first { $0.url?.host() == "api.trakt.tv" })
        #expect(list.url?.path() == "/shows/trending")
        #expect(query(list, "limit") == "20" && query(list, "extended") == "full")
        #expect(list.value(forHTTPHeaderField: "trakt-api-key") == "cid")
        #expect(list.value(forHTTPHeaderField: "trakt-api-version") == "2")

        // a day's posters and an hour's list: nothing asked the second time
        func upstream() -> Int {
            transport.requests.filter { $0.url?.path().hasSuffix("/lookup") == true || $0.url?.host() == "api.trakt.tv" }
                .count
        }
        let before = upstream()
        _ = try await direct.traktList(movies: false, list: .trending)
        #expect(upstream() == before)
    }

    @Test func popularFilmsAreNotWrappedAndNeedNoRadarr() async throws {
        let (direct, transport) = backend(["trakt": ServiceConnection(apiKey: "cid")])
        transport.on("GET /movies/popular", json: #"[{"title": "Heat", "year": 1995, "ids": {"tmdb": 949}}]"#)
        let rows = try await direct.traktList(movies: true, list: .popular)
        #expect(rows.map(\.remote_id) == [949])
        #expect(rows[0].kind == "movie" && rows[0].tmdb_id == 949 && rows[0].poster == nil && rows[0].in_library == false)
        #expect(rows[0].editions == [])
    }

    @Test func aFailedLookupIsTriedAgainNextTime() async throws {
        let (direct, transport) = backend(["trakt": ServiceConnection(apiKey: "cid"), "radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /movies/trending", json: #"[{"movie": {"title": "Heat", "ids": {"tmdb": 949}}}]"#)
        transport.on("GET /api/v3/movie", json: "[]")
        transport.on("GET /api/v3/movie/lookup", status: 500, json: "")
        #expect(try await direct.traktList(movies: true, list: .trending).first?.poster == nil)
        transport.on("GET /api/v3/movie/lookup", json: #"""
        [{"images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/h.jpg"}]}]
        """#)
        #expect(try await direct.traktList(movies: true, list: .trending).first?.poster == "https://image.tmdb.org/t/p/w500/h.jpg")
    }
}
