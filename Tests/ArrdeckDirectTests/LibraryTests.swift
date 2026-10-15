import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

private func body(_ request: URLRequest) -> JSON {
    (try? JSON(data: request.httpBody ?? Data())) ?? .null
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
}

private func ok(_ json: String) -> ServiceResponse {
    ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
}

private let radarr = ServiceConnection.arr("http://10.0.0.5:7878")
private let readarr = ServiceConnection.arr("http://10.0.0.5:8787")
private let lidarr = ServiceConnection.arr("http://10.0.0.5:8686")

struct MovieDetailTests {
    @Test func aFilmReadsItsFileRatingsArtworkAndHistory() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/movie/7", json: """
        {"id": 7, "title": "Dune", "year": 2021, "monitored": true, "hasFile": true, "sizeOnDisk": 5000,
         "qualityProfileId": 4, "tmdbId": 438631, "imdbId": "tt1160419", "runtime": 155,
         "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/p.jpg"},
                    {"coverType": "fanart", "remoteUrl": "https://image.tmdb.org/t/p/original/f.jpg"}],
         "ratings": {"tmdb": {"value": 7.8, "votes": 900}, "imdb": {"value": 8.0, "votes": 0},
                     "metacritic": {"value": 0}},
         "movieFile": {"size": 4900, "releaseGroup": "FLUX", "mediaInfo": {"resolution": "3840x1606"},
                       "quality": {"quality": {"name": "WEBDL-2160p"}}}}
        """)
        transport.on("GET /api/v3/history/movie", json: """
        [{"eventType": "downloadFolderImported", "date": "2024-05-02T10:00:00Z"},
         {"eventType": "grabbed", "date": "2024-05-01T10:00:00Z"}, {"eventType": "somethingNew", "date": "x"}]
        """)
        let movie = try await direct.movieDetail(7)
        #expect(movie.poster == "https://image.tmdb.org/t/p/w500/p.jpg")
        #expect(movie.fanart == "https://image.tmdb.org/t/p/w1280/f.jpg")
        // IMDb before TMDB whatever order the arr sent, empty sources dropped, no votes is nil
        #expect(movie.ratings?.map(\.source) == ["imdb", "tmdb"])
        #expect(movie.ratings?.first?.votes == nil)
        #expect(movie.file == MovieFile(quality: "WEBDL-2160p", release_group: "FLUX", resolution: "3840x1606", size: 4900))
        #expect(movie.history?.map(\._type) == ["imported", "fetched", "somethingNew"])
    }

    @Test func aFilmOpensWithoutItsHistory() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/movie/7", json: #"{"id": 7, "title": "Dune"}"#)
        transport.on("GET /api/v3/history/movie", status: 500, json: "")
        let movie = try await direct.movieDetail(7)
        #expect(movie.history == [])
        #expect(movie.file == nil)
        #expect(movie.monitored == false)
    }

    @Test func anUnconfiguredRadarrIsTheServicesProblem() async throws {
        let (direct, _) = backend([:])
        await #expect(throws: APIError.refused("not configured")) { try await direct.movieDetail(7) }
    }
}

struct CreditsTests {
    static func headshot(_ name: String) -> String {
        #"[{"coverType": "headshot", "url": "/MediaCoverProxy/\#(name).jpg", "remoteUrl": "https://image.tmdb.org/t/p/original/\#(name).jpg"}]"#
    }

    @Test func castByBillingAndTheCrewWorthNaming() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/credit", json: """
        [{"type": "cast", "personName": "Second", "character": "B", "order": 1, "images": []},
         {"type": "cast", "personName": "Unordered", "character": "C", "images": []},
         {"type": "cast", "personName": "Lead", "character": "A", "order": 0, "personTmdbId": 9, "images": \(Self.headshot("lead"))},
         {"type": "crew", "personName": "W1", "job": "Screenplay", "images": []},
         {"type": "crew", "personName": "W2", "job": "Screenplay", "images": []},
         {"type": "crew", "personName": "W3", "job": "Screenplay", "images": []},
         {"type": "crew", "personName": "W1", "job": "Story", "images": []},
         {"type": "crew", "personName": "Painter", "job": "Painter", "images": []},
         {"type": "crew", "personName": "Helmer", "job": "Director", "images": []}]
        """)
        let credits = try await direct.movieCredits(7)
        #expect(credits.cast?.map(\.name) == ["Lead", "Second", "Unordered"])
        #expect(credits.cast?.first?.image == "https://image.tmdb.org/t/p/w185/lead.jpg")
        #expect(credits.cast?.first?.tmdb_id == 9)
        // the director first, two writers at most, a name once
        #expect(credits.crew?.map(\.name) == ["Helmer", "W1", "W2"])
        #expect(credits.crew?.map(\.role) == ["Director", "Screenplay", "Screenplay"])
    }

    @Test func creditsAreKeptPerFilm() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/credit", json: "[]")
        _ = try await direct.movieCredits(7)
        _ = try await direct.movieCredits(7)
        _ = try await direct.movieCredits(8)
        #expect(transport.requests.count == 2)
    }
}

struct SeriesTests {
    @Test func seasonsInOrderAndSonarrsSingleRatingIsIMDbs() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series/5", json: """
        {"id": 5, "title": "Severance", "ratings": {"value": 8.7, "votes": 1000},
         "statistics": {"episodeCount": 19, "episodeFileCount": 18, "totalEpisodeCount": 20, "seasonCount": 2},
         "seasons": [{"seasonNumber": 2, "monitored": true, "statistics": {"episodeCount": 10}},
                     {"seasonNumber": 0, "monitored": false}, {"seasonNumber": 1, "monitored": true}]}
        """)
        let series = try await direct.seriesDetail(5)
        #expect(series.seasons.map(\.number) == [0, 1, 2])
        #expect(series.seasons.last?.episode_count == 10)
        #expect(series.ratings == [Rating(source: "imdb", value: 8.7, votes: 1000)])
        #expect(series.total_episode_count == 20)
    }

    @Test func oneSeasonsEpisodesWithTheirFiles() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/episode") { request in
            #expect(query(request) == ["seriesId": "5", "includeEpisodeFile": "true"])
            return ok("""
            [{"id": 3, "seasonNumber": 2, "episodeNumber": 2, "overview": "", "episodeFileId": 0},
             {"id": 2, "seasonNumber": 2, "episodeNumber": 1, "hasFile": true, "monitored": true,
              "episodeFile": {"id": 77, "size": 1234, "quality": {"quality": {"name": "WEBDL-1080p"}}}},
             {"id": 4, "seasonNumber": 2, "episodeNumber": 3, "episodeFileId": 88},
             {"id": 1, "seasonNumber": 1, "episodeNumber": 1}]
            """)
        }
        let episodes = try await direct.episodes(series: 5, season: 2)
        #expect(episodes.map(\.id) == [2, 3, 4])
        #expect(episodes[0].file_id == 77 && episodes[0].quality == "WEBDL-1080p" && episodes[0].size == 1234)
        // Sonarr's 0 means no file, and an empty overview is none
        #expect(episodes[1].file_id == nil && episodes[1].overview == nil)
        #expect(episodes[2].file_id == 88)
    }

    @Test func aSeasonsFlagIsSetInTheWholeSeries() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series/5", json: """
        {"id": 5, "title": "Severance", "seasons": [{"seasonNumber": 1, "monitored": true}, {"seasonNumber": 2, "monitored": false}]}
        """)
        let sent = Locked<JSON>(.null)
        transport.on("PUT /api/v3/series/5") { request in
            sent.withLock { $0 = body(request) }
            return ok("{}")
        }
        try await direct.setSeasonMonitored(series: 5, season: 2, monitored: true)
        #expect(sent.current["title"].string == "Severance")
        #expect(sent.current["seasons"].array.map { $0["monitored"].bool } == [true, true])
        await #expect(throws: APIError.unexpectedStatus(404)) {
            try await direct.setSeasonMonitored(series: 5, season: 9, monitored: true)
        }
    }
}

struct EditTests {
    @Test func anEditSendsTheWholeFilmBackChanged() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/movie/7", json: #"{"id": 7, "title": "Dune", "monitored": false, "qualityProfileId": 1}"#)
        let sent = Locked<JSON>(.null)
        transport.on("PUT /api/v3/movie/7") { request in
            sent.withLock { $0 = body(request) }
            return ok("{}")
        }
        try await direct.update(.movie(7), monitored: true, qualityProfile: 4)
        #expect(sent.current == ["id": 7, "title": "Dune", "monitored": true, "qualityProfileId": 4])
    }

    @Test func aBooksFlagGoesOnTheBookWithItsEditionsAndItsQualityOnTheAuthor() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/book/146", json: #"{"id": 146, "authorId": 3, "monitored": false}"#)
        transport.on("GET /api/v1/edition", json: #"[{"id": 1, "monitored": true}]"#)
        transport.on("GET /api/v1/author/3", json: #"{"id": 3, "qualityProfileId": 1}"#)
        let book = Locked<JSON>(.null), author = Locked<JSON>(.null)
        transport.on("PUT /api/v1/book/146") { request in
            book.withLock { $0 = body(request) }
            return ok(#"{"id": 146, "authorId": 3, "monitored": true}"#)
        }
        transport.on("PUT /api/v1/author/3") { request in
            author.withLock { $0 = body(request) }
            return ok("{}")
        }
        try await direct.update(.book(146), monitored: true, qualityProfile: 2)
        #expect(book.current["monitored"] == true)
        #expect(book.current["editions"] == [["id": 1, "monitored": true]])
        #expect(author.current["qualityProfileId"] == 2)
    }

    @Test func anAlbumsFlagUsesLidarrsToggleAndNothingElseIsSent() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("PUT /api/v1/album/monitor", json: "{}")
        try await direct.update(.album(9), monitored: nil, qualityProfile: 3)
        #expect(transport.requests.isEmpty)
        try await direct.update(.album(9), monitored: false, qualityProfile: nil)
        #expect(body(transport.requests[0]) == ["albumIds": [9], "monitored": false])
    }

    @Test func deletingSaysWhetherTheFilesGoToo() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("DELETE /api/v3/movie/7", json: "")
        try await direct.delete(.movie(7), deleteFiles: true)
        #expect(query(transport.requests[0]) == ["deleteFiles": "true", "addImportExclusion": "false"])
        await #expect(throws: APIError.unexpectedStatus(405)) { try await direct.delete(.album(1), deleteFiles: false) }
    }

    @Test func eachArrIsAskedToSearchInItsOwnTerms() async throws {
        let (direct, transport) = backend(["radarr": radarr, "lidarr": lidarr, "sonarr": .arr()])
        transport.on("POST /api/v3/command", json: "{}")
        transport.on("POST /api/v1/command", json: "{}")
        try await direct.triggerSearch(.movie(7))
        try await direct.triggerSearch(.artist(2))
        try await direct.searchAlbum(9)
        try await direct.searchSeason(series: 5, season: 1)
        #expect(transport.requests.map(body) == [
            ["name": "MoviesSearch", "movieIds": [7]],
            ["name": "ArtistSearch", "artistId": 2],
            ["name": "AlbumSearch", "albumIds": [9]],
            ["name": "SeasonSearch", "seriesId": 5, "seasonNumber": 1],
        ])
    }

    @Test func optionsCarryMetadataProfilesForReadarrAndAreKept() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/qualityprofile", json: #"[{"id": 1, "name": "eBook"}]"#)
        transport.on("GET /api/v1/rootfolder", json: #"[{"id": 2, "path": "/books", "freeSpace": 123456789012}]"#)
        transport.on("GET /api/v1/metadataprofile", json: #"[{"id": 3, "name": "Standard"}]"#)
        let options = try await direct.options(.readarr)
        #expect(options.quality_profiles == [QualityProfile(id: 1, name: "eBook")])
        #expect(options.root_folders == [RootFolder(free_space: 123_456_789_012, id: 2, path: "/books")])
        #expect(options.metadata_profiles == [QualityProfile(id: 3, name: "Standard")])
        _ = try await direct.options(.readarr)
        #expect(transport.requests.count == 3)
    }
}

struct BookTests {
    static let books = """
    [{"id": 146, "authorId": 3, "title": "Count Zero", "monitored": true, "releaseDate": "1986-03-01T00:00:00Z",
      "statistics": {"bookFileCount": 1}},
     {"id": 147, "authorId": 3, "title": "Mona Lisa Overdrive", "monitored": false, "releaseDate": "1988-01-01T00:00:00Z"},
     {"id": 145, "authorId": 3, "title": "Neuromancer", "monitored": true, "releaseDate": "1984-07-01T00:00:00Z"},
     {"id": 200, "authorId": 4, "title": "Elsewhere", "monitored": true}]
    """
    static let series = """
    [{"id": 10, "title": "Sprawl", "links": [{"bookId": 147, "position": "3", "seriesPosition": 3},
                                            {"bookId": 145, "position": "1", "seriesPosition": 1},
                                            {"bookId": 146, "position": "2", "seriesPosition": 2},
                                            {"bookId": 999, "position": "4", "seriesPosition": 4}]},
     {"id": 11, "title": "Unrelated", "links": [{"bookId": 145, "position": "1", "seriesPosition": 1}]}]
    """

    @Test func aBookPageJoinsItsAuthorSeriesAndFiles() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/book/146", json: """
        {"id": 146, "authorId": 3, "title": "Count Zero", "monitored": true, "pageCount": 0,
         "ratings": {"value": 3.9, "votes": 40}, "links": [{"name": "Goodreads Book", "url": "https://goodreads.com/b/1"}],
         "images": [{"coverType": "cover", "url": "/MediaCover/1.jpg", "remoteUrl": "https://images.gr-assets.com/1.jpg"}],
         "editions": [{"title": "Count Zero", "format": "Paperback", "isEbook": false, "monitored": true}]}
        """)
        transport.on("GET /api/v1/author/3", json: #"{"id": 3, "authorName": "William Gibson", "qualityProfileId": 2}"#)
        transport.on("GET /api/v1/history", json: #"{"records": [{"eventType": "bookFileImported", "date": "2024-01-01"}]}"#)
        transport.on("GET /api/v1/bookfile", json: #"[{"id": 5, "path": "/books/Gibson/Count Zero.epub", "size": 300, "quality": {"quality": {"name": "EPUB"}}}]"#)
        transport.on("GET /api/v1/book", json: Self.books)
        transport.on("GET /api/v1/series", json: Self.series)
        let book = try await direct.bookDetail(146)
        #expect(book.author == "William Gibson" && book.quality_profile_id == 2)
        #expect(book.poster == "https://images.gr-assets.com/1.jpg")
        #expect(book.goodreads_url == "https://goodreads.com/b/1")
        #expect(book.page_count == nil)
        #expect(book.files == [BookFile(format: "EPUB", id: 5, name: "Count Zero.epub", size: 300)])
        #expect(book.downloadable == false)
        #expect(book.history?.map(\._type) == ["imported"])
        // only the series this book is in, in series order, unknown ids left out
        #expect(book.series?.map(\.title) == ["Sprawl"])
        #expect(book.series?.first?.books?.map(\.book_id) == [145, 146, 147])
        #expect(book.series?.first?.books?.map(\.position) == ["1", "2", "3"])
    }

    @Test func aBookPageOpensWhenItsDecorationFails() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/book/146", json: #"{"id": 146, "authorId": 3, "title": "Count Zero"}"#)
        let book = try await direct.bookDetail(146)
        #expect(book.title == "Count Zero" && book.author == nil && book.series == [] && book.files == [])
    }

    @Test func anAuthorsBooksByYearAndTheirSeries() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/author/3", json: """
        {"id": 3, "authorName": "William Gibson", "monitorNewItems": "none", "overview": "Sprawl",
         "statistics": {"bookCount": 3, "availableBookCount": 1, "sizeOnDisk": 300}}
        """)
        transport.on("GET /api/v1/book", json: Self.books)
        transport.on("GET /api/v1/series", json: Self.series)
        let author = try await direct.authorDetail(3)
        #expect(author.books?.map(\.id) == [145, 146, 147])
        #expect(author.books?.first?.author == "William Gibson")
        #expect(author.books?[1].has_file == true)
        #expect(author.series?.map(\.title) == ["Sprawl", "Unrelated"])
        #expect((author.monitor_new_items, author.book_count, author.available_count) == ("none", 3, 1))
    }

    @Test func theShelfKeepsSeriesWithALibraryBookAndAllTheirGaps() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/author", json: #"[{"id": 3, "authorName": "William Gibson"}]"#)
        transport.on("GET /api/v1/book", json: """
        [{"id": 1, "authorId": 3, "title": "Book 1", "monitored": false, "statistics": {"bookFileCount": 1}},
         {"id": 2, "authorId": 3, "title": "Book 2", "monitored": false},
         {"id": 3, "authorId": 3, "title": "Book 3", "monitored": false}]
        """)
        transport.on("GET /api/v1/series", json: """
        [{"id": 10, "title": "Sprawl", "links": [{"bookId": 2, "position": "2", "seriesPosition": 2},
                                                {"bookId": 1, "position": "1", "seriesPosition": 1}]},
         {"id": 11, "title": "Unowned", "links": [{"bookId": 3, "position": "1", "seriesPosition": 1}]}]
        """)
        let shelf = try await direct.bookShelf()
        #expect(shelf.map(\.title) == ["Sprawl"])
        #expect(shelf.first?.author == "William Gibson")
        #expect(shelf.first?.books?.map(\.book_id) == [1, 2])
        #expect(shelf.first?.books?.last?.has_file == false)
    }

    @Test func editionsOfTheWorkForThePicker() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/book/lookup") { request in
            #expect(query(request)["term"] == "edition:123")
            return ok("""
            [{"editions": [{"foreignEditionId": "123", "title": "Neuromancer", "format": "Paperback", "language": "eng",
                            "releaseDate": "2000-07-01T00:00:00Z", "pageCount": 0, "monitored": true},
                           {"title": "no id"}]}]
            """)
        }
        let editions = try await direct.bookEditions(edition: "123")
        #expect(editions == [EditionChoice(
            foreign_edition_id: "123", format: "Paperback", language: "eng", monitored: true, page_count: nil,
            title: "Neuromancer", year: 2000
        )])
    }
}

struct SubtitleTests {
    static let bazarr = ServiceConnection.arr("http://10.0.0.5:6767")

    @Test func presentAndMissingTracksAndWhetherTheTitleIsTracked() async throws {
        let (direct, transport) = backend(["bazarr": Self.bazarr])
        transport.on("GET /api/movies") { request in
            #expect(query(request)["radarrid[]"] == "7")
            return ok("""
            {"data": [{"profileId": 1,
              "subtitles": [{"name": "Danish", "code2": "da", "path": "/x.da.srt", "forced": false, "hi": false}],
              "missing_subtitles": [{"name": "", "code2": "en", "hi": true}]}]}
            """)
        }
        let movie = try await direct.movieSubtitles(7)
        #expect(movie.tracked == true)
        #expect(movie.present == [SubtitleTrack(code: "da", forced: false, hi: false, language: "Danish", path: "/x.da.srt")])
        #expect(movie.missing == [SubtitleTrack(code: "en", forced: false, hi: true, language: "en", path: nil)])

        transport.on("GET /api/movies", json: #"{"data": [{"profileId": null, "subtitles": []}]}"#)
        #expect(try await direct.movieSubtitles(7).tracked == false)
        transport.on("GET /api/movies", json: #"{"data": []}"#)
        #expect(try await direct.movieSubtitles(7) == TitleSubtitles(missing: [], present: [], tracked: false))
    }

    @Test func episodeRowsCarryNoProfileSoTheyCountAsTracked() async throws {
        let (direct, transport) = backend(["bazarr": Self.bazarr])
        transport.on("GET /api/episodes", json: """
        {"data": [{"sonarrEpisodeId": 12, "season": 1, "episode": 2, "subtitles": [], "missing_subtitles": []},
                  {"sonarrEpisodeId": 0, "season": 1, "episode": 3}]}
        """)
        let rows = try await direct.seriesSubtitles(5)
        #expect(rows.map(\.episode_id) == [12])
        #expect(rows.first?.subtitles.tracked == true)
    }

    @Test func aDownloadIsAPatchWithTheLanguageInTheQuery() async throws {
        let (direct, transport) = backend(["bazarr": Self.bazarr])
        transport.on("PATCH /api/episodes/subtitles", status: 204, json: "")
        try await direct.downloadSubtitle(.episode(series: 5, episode: 12), language: "da")
        #expect(query(transport.requests[0]) == ["seriesid": "5", "episodeid": "12", "language": "da", "hi": "false", "forced": "false"])
    }
}

struct WatchedTests {
    static let plex = ServiceConnection(url: "http://10.0.0.5:32400", apiKey: "token")

    @Test func everyIDPlexKnowsMapsToTheTitlesWatchState() async throws {
        let (direct, transport) = backend(["plex": Self.plex])
        transport.on("GET /identity", json: #"{"MediaContainer": {"machineIdentifier": "abc"}}"#)
        transport.on("GET /library/sections", json: """
        {"MediaContainer": {"Directory": [{"key": "1", "type": "movie"}, {"key": "2", "type": "show"},
                                          {"key": "3", "type": "artist"}, {"key": "4", "type": "movie"}]}}
        """)
        transport.on("GET /library/sections/1/all") { request in
            #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "token")
            #expect(query(request) == ["includeGuids": "1"])
            return ok("""
            {"MediaContainer": {"Metadata": [{"ratingKey": "10", "viewCount": 2, "lastViewedAt": 1700000000,
              "Guid": [{"id": "imdb://tt1160419"}, {"id": "tmdb://438631"}]}]}}
            """)
        }
        transport.on("GET /library/sections/2/all", json: """
        {"MediaContainer": {"Metadata": [{"ratingKey": "20", "leafCount": 4, "viewedLeafCount": 1, "Guid": [{"id": "tvdb://371980"}]}]}}
        """)
        transport.on("GET /library/sections/4/all", status: 500, json: "")
        let block = try await direct.watched()
        let map = try #require(block.value)
        #expect(map.base_url == "https://app.plex.tv/desktop/#!/server/abc/details?key=/library/metadata/")
        let items = try #require(map.items?.additionalProperties)
        #expect(Set(items.keys) == ["imdb:tt1160419", "tmdb:438631", "tvdb:371980"])
        #expect(items["tmdb:438631"] == WatchedItem(key: "10", last_viewed_at: 1_700_000_000, progress: 1, watched: true))
        #expect(items["tvdb:371980"] == WatchedItem(key: "20", last_viewed_at: nil, progress: 0.25, watched: false))
        #expect(!transport.requests.contains { $0.url?.path() == "/library/sections/3/all" })
    }

    @Test func withoutPlexTheBlockSaysSo() async throws {
        let (direct, _) = backend([:])
        #expect(try await direct.watched() == .offline("not configured"))
    }
}

struct WantedTests {
    @Test func sonarrsRowsAreEpisodesUnderTheirSeries() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/wanted/missing") { request in
            #expect(query(request) == [
                "page": "2", "pageSize": "30", "sortKey": "airDateUtc", "sortDirection": "descending",
                "monitored": "true", "includeSeries": "true",
            ])
            return ok("""
            {"totalRecords": 61, "records": [{"id": 900, "seriesId": 5, "seasonNumber": 1, "episodeNumber": 4,
              "title": "The You You Are", "airDateUtc": "2022-03-11T02:00:00Z", "lastSearchTime": "2024-05-01T12:00:00.123Z",
              "series": {"title": "Severance", "images": [{"coverType": "poster", "remoteUrl": "https://artworks.thetvdb.com/p.jpg"}]}}]}
            """)
        }
        let page = try await direct.wanted(.sonarr, kind: .missing, page: 2)
        #expect(page.has_more == true && page.total == 61)
        let item = try #require(page.items.first)
        #expect((item.id, item.library_id, item.title) == (900, 5, "Severance"))
        #expect(item.subtitle == "S01E04 The You You Are")
        #expect(item.poster == "https://artworks.thetvdb.com/p.jpg")
        #expect(item.last_search != nil)
        #expect(item.ref == .series(5))
    }

    @Test func radarrsRowNamesTheYearAndTheFirstReleaseDate() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/wanted/cutoff", json: """
        {"totalRecords": 30, "records": [{"id": 7, "title": "Dune", "year": 2021, "physicalRelease": "2022-01-11T00:00:00Z",
                                          "inCinemas": "2021-10-22T00:00:00Z"}]}
        """)
        let page = try await direct.wanted(.radarr, kind: .cutoff, page: 1)
        #expect(page.has_more == false)
        #expect(page.items.first?.subtitle == "2021")
        #expect(page.items.first?.air_date == "2022-01-11T00:00:00Z")
    }

    @Test func searchAllRunsTheArrsOwnJob() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("POST /api/v1/command", json: "{}")
        try await direct.searchAllWanted(.lidarr, kind: .cutoff)
        #expect(body(transport.requests[0]) == ["name": "CutoffUnmetAlbumSearch"])
    }
}

struct DiagnoseTests {
    @Test func aFailedImportInTheQueueLeadsAndTheRestFollowWorstFirst() async throws {
        let (direct, transport) = backend(["radarr": radarr, "prowlarr": .arr("http://10.0.0.5:9696")])
        transport.on("GET /api/v3/movie/85", json: """
        {"id": 85, "title": "Roofman", "monitored": true, "isAvailable": true, "lastSearchTime": "2025-10-01T10:00:00Z"}
        """)
        transport.on("GET /api/v3/queue", json: """
        {"records": [{"id": 1, "movieId": 85, "status": "downloading", "trackedDownloadState": "importPending", "sizeleft": 0,
                      "statusMessages": [{"title": "x", "messages": ["No space left"]}]},
                     {"id": 2, "movieId": 99, "status": "downloading", "sizeleft": 10}]}
        """)
        transport.on("GET /api/v3/blocklist", json: """
        {"records": [{"movieId": 85, "sourceTitle": "Roofman 2025 1080p WEB h264-ETHEL", "indexer": "TLTorznab",
                      "message": "Manually marked as failed"}, {"movieId": 85}]}
        """)
        transport.on("GET /api/v3/system/task", json: #"[{"name": "RSS Sync", "taskName": "RssSync", "lastExecution": "2020-01-01T00:00:00Z"}]"#)
        transport.on("GET /api/v3/delayprofile", json: #"[{"usenetDelay": 0, "torrentDelay": 30, "bypassIfHighestQuality": true}]"#)
        transport.on("GET /api/v1/indexer", json: #"[{"id": 1, "enable": true}, {"id": 2, "enable": false}]"#)
        transport.on("GET /api/v1/health", json: """
        [{"type": "warning", "source": "UpdateCheck", "message": "New update is available"},
         {"type": "error", "source": "IndexerStatusCheck", "message": "Indexers unavailable due to failures: TLTorznab"}]
        """)
        let diagnosis = try await direct.diagnose(.radarr, id: 85)
        #expect(diagnosis.title == "Roofman")
        let codes = diagnosis.findings?.map(\.code)
        #expect(codes == ["queue_failed", "blocklisted", "indexers_failing", "last_searched", "rss_stale", "delay_profile"])
        let findings = try #require(diagnosis.findings)
        #expect(findings[0].parameters["reason"] == "No space left")
        #expect(findings[1].parameters["count"] == "2" && findings[1].parameters["indexer"] == "TLTorznab")
        #expect(findings[2].parameters["total"] == "1")
        #expect(findings[5].parameters["bypass"] == "yes" && findings[5].parameters["torrent"] == "30")
        #expect(DiagnosisText.sentence(for: findings[0]).contains("No space left"))
    }

    @Test func anUnreleasedFilmIsTheAnswer() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/movie/7", json: """
        {"id": 7, "title": "Later", "monitored": true, "isAvailable": false, "minimumAvailability": "released",
         "physicalRelease": "2027-01-05T00:00:00Z"}
        """)
        let findings = try #require(try await direct.diagnose(.radarr, id: 7).findings)
        #expect(findings.map(\.code) == ["not_yet_available", "never_searched"])
        #expect(findings[0].parameters == ["availability": "released", "date": "2027-01-05"])
    }

    @Test func aDownloadingAlbumIsOnItsWay() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("GET /api/v1/album/1", json: #"{"id": 1, "title": "Geogaddi", "monitored": true, "artist": {"monitored": true}}"#)
        transport.on("GET /api/v1/queue", json: #"{"records": [{"id": 3, "albumId": 1, "title": "t", "sizeleft": 5, "size": 9}]}"#)
        let codes = try await direct.diagnose(.lidarr, id: 1).findings?.map(\.code)
        #expect(codes == ["never_searched", "queue_downloading"])
    }

    @Test func aTitleTheArrDoesNotHaveIsNotFound() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/series/5", status: 404, json: "")
        await #expect(throws: APIError.unexpectedStatus(404)) { try await direct.diagnose(.sonarr, id: 5) }
        await #expect(throws: APIError.unexpectedStatus(404)) { try await direct.diagnose(.readarr, id: 5) }
    }
}
