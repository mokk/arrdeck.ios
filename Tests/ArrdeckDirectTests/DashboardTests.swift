import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

private func json(_ text: String) throws -> JSON {
    try JSON(data: Data(text.utf8))
}

private func body(_ request: URLRequest?) throws -> JSON {
    try JSON(data: try #require(request?.httpBody))
}

private func query(_ request: URLRequest?) -> [String: String] {
    let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
}

private let sonarr = ServiceConnection.arr("http://10.0.0.5:8989")
private let radarr = ServiceConnection.arr("http://10.0.0.5:7878")
private let lidarr = ServiceConnection.arr("http://10.0.0.5:8686")

struct QueueTests {
    @Test func aShowsItemIsNamedForTheShowAndSaysWhyItIsStuck() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/queue", json: """
        {"records": [{
          "id": 7, "title": "Show.S01E02.1080p", "series": {"title": "Show"}, "status": "completed",
          "trackedDownloadState": "importBlocked", "trackedDownloadStatus": "warning",
          "size": 1000, "sizeleft": 250, "timeleft": "00:01:00", "seriesId": 3, "episodeId": 9,
          "statusMessages": [
            {"title": "Show.S01E02.mkv", "messages": ["No files found are eligible", "second line"]},
            {"title": "nothing to say", "messages": []}
          ]
        }]}
        """)
        let queue = try await direct.queue()
        // Radarr is always answered for, Readarr and Lidarr only once set up
        #expect(Set(queue.keys) == [.radarr, .sonarr])
        #expect(queue[.radarr] == .offline("not configured"))
        let item = try #require(queue[.sonarr]?.value?.first)
        #expect(item.title == "Show — Show.S01E02.1080p")
        #expect(item.errors == ["No files found are eligible"])
        #expect(item.status_messages?.count == 2)
        #expect(item.needs_attention == true)
        #expect(item.size_left == 250)
        #expect(item.series_id == 3 && item.episode_id == 9 && item.album_id == nil)
        let sent = query(transport.requests.first { $0.url?.path().hasSuffix("/queue") == true })
        #expect(sent["includeSeries"] == "true" && sent["includeUnknownSeriesItems"] == "true" && sent["pageSize"] == "50")
    }

    @Test func anAlbumIsNamedForItsArtistAndCarriesItsIDs() throws {
        let payload = try json("""
        {"records": [{"id": 1, "title": "Artist-Album-WEB-FLAC", "album": {"title": "Album"},
          "artist": {"artistName": "Artist"}, "albumId": 5, "artistId": 2, "status": "downloading"}]}
        """)
        let item = try #require(DashboardPort.queueItems(app: .lidarr, payload: payload).first)
        #expect(item.title == "Artist — Album")
        #expect(item.album_id == 5 && item.artist_id == 2)
        #expect(item.needs_attention == false)
    }
}

struct HistoryConsolidationTests {
    private func record(_ event: String, _ date: String, download: String = "abc", title: String = "Some.Release",
                        movie: Int? = nil) -> JSON {
        [
            "eventType": .string(event), "date": .string(date), "downloadId": .string(download),
            "sourceTitle": .string(title), "movieId": JSON(movie),
            "quality": ["quality": ["name": "WEBDL-1080p"]],
        ]
    }

    @Test func aDownloadIsOneRowWithItsEventsInOrderOnce() {
        let payload: JSON = ["records": [
            record("downloadFolderImported", "2026-01-02T00:00:00Z"),
            record("grabbed", "2026-01-01T00:00:00Z"),
            record("grabbed", "2026-01-01T01:00:00Z"),
        ]]
        let out = DashboardPort.consolidateHistory(app: .radarr, payload: payload)
        #expect(out.count == 1)
        #expect(out[0].events?.map(\._type) == ["fetched", "imported"])
        #expect(out[0].date == "2026-01-02T00:00:00Z")
        #expect(out[0].quality == "WEBDL-1080p")
    }

    @Test func separateDownloadsStaySeparateNewestFirst() {
        let payload: JSON = ["records": [
            record("grabbed", "2026-01-01T00:00:00Z", download: "a", title: "A"),
            record("grabbed", "2026-01-05T00:00:00Z", download: "b", title: "B"),
        ]]
        #expect(DashboardPort.consolidateHistory(app: .radarr, payload: payload).map(\.title) == ["B", "A"])
    }

    @Test func aRowKnowsTheTitleItOpens() {
        let payload: JSON = ["records": [record("grabbed", "2026-01-01T00:00:00Z", movie: 42)]]
        #expect(DashboardPort.consolidateHistory(app: .radarr, payload: payload).first?.movie_id == 42)
    }

    @Test func aManualAlbumImportIsOneRowAnHour() throws {
        let payload = try json("""
        {"records": [
          {"eventType": "trackFileImported", "date": "2026-01-01T10:40:00Z", "albumId": 5, "sourceTitle": "02.flac",
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}},
          {"eventType": "trackFileImported", "date": "2026-01-01T10:05:00Z", "albumId": 5, "sourceTitle": "01.flac",
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}},
          {"eventType": "trackFileImported", "date": "2026-01-01T11:02:00Z", "albumId": 5, "sourceTitle": "03.flac",
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}}
        ]}
        """)
        let out = DashboardPort.consolidateHistory(app: .lidarr, payload: payload)
        #expect(out.count == 2)
        #expect(out.map(\.title) == ["Artist — Album", "Artist — Album"])
        #expect(out.map(\.date) == ["2026-01-01T11:02:00Z", "2026-01-01T10:40:00Z"])
        #expect(out.allSatisfy { $0.album_id == 5 })
    }

    @Test func aHistoryPageMergesTheArrsAndSaysWhenThereIsMore() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("GET /api/v3/history") { request in
            let full = request.url?.port == 7878
            let records = (0 ..< (full ? 50 : 1)).map { i in
                #"{"eventType": "grabbed", "date": "2026-01-\#(full ? "01" : "09")T00:00:\#(String(format: "%02d", i % 60))Z", "downloadId": "\#(full ? "r" : "s")\#(i)", "sourceTitle": "T\#(i)"}"#
            }
            return ServiceResponse(status: 200, headers: [:], data: Data(#"{"records": [\#(records.joined(separator: ","))]}"#.utf8))
        }
        let page = try await direct.historyPage(2)
        #expect(page.has_more == true)
        #expect(page.items.count == 51)
        #expect(page.items.first?.app == "sonarr")
        #expect(query(transport.requests.first)["page"] == "2")
    }
}

struct CalendarTests {
    private let start = "2026-08-01", end = "2026-08-31"

    @Test func theReleaseInsideTheWindowIsTheOneShown() throws {
        let movie = try json(#"{"inCinemas": "2026-03-01T00:00:00Z", "digitalRelease": "2026-08-10T00:00:00Z"}"#)
        #expect(DashboardPort.releaseInfo(movie, start: start, end: end)?.date == "2026-08-10T00:00:00Z")
        #expect(DashboardPort.releaseInfo(movie, start: start, end: end)?.kind == "digital")
    }

    @Test func discDatesAndPastDatesAreNotReleases() throws {
        #expect(DashboardPort.releaseInfo(try json(#"{"physicalRelease": "2026-08-15T00:00:00Z"}"#), start: start, end: end) == nil)
        #expect(DashboardPort.releaseInfo(try json(#"{"inCinemas": "2026-03-01T00:00:00Z"}"#), start: start, end: end) == nil)
    }

    @Test func theEarliestReleaseInTheWindowWins() throws {
        let movie = try json(#"{"inCinemas": "2026-08-05T00:00:00Z", "digitalRelease": "2026-08-20T00:00:00Z"}"#)
        #expect(DashboardPort.releaseInfo(movie, start: start, end: end)?.kind == "cinema")
    }

    @Test func aWindowAsksEachArrAndNamesItsEntries() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("GET /api/v3/calendar") { request in
            let text = request.url?.port == 7878
                ? #"""
                [{"id": 1, "title": "Film", "digitalRelease": "2026-08-10T00:00:00Z", "hasFile": false,
                  "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/f.jpg"}]},
                 {"id": 2, "title": "Disc only", "physicalRelease": "2026-08-12T00:00:00Z"}]
                """#
                : #"""
                [{"seriesId": 3, "seasonNumber": 1, "episodeNumber": 2, "title": "Pilot", "airDateUtc": "2026-08-03T01:00:00Z",
                  "finaleType": "season", "series": {"title": "Show"}}]
                """#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        let calendar = try await direct.calendar(start: start, days: 30)
        #expect(Set(calendar.keys) == [.radarr, .sonarr])
        let films = try #require(calendar[.radarr]?.value)
        #expect(films.map(\.title) == ["Film"])
        #expect(films[0].poster == "https://image.tmdb.org/t/p/w500/f.jpg")
        #expect(films[0].release_type == "digital")
        let episode = try #require(calendar[.sonarr]?.value?.first)
        #expect(episode.title == "Show" && episode.extra == "S01E02 Pilot" && episode.item_id == 3)
        #expect(episode.finale_type == "season")
        let sonarrQuery = query(transport.requests.first { $0.url?.port == 8989 })
        #expect(sonarrQuery["start"] == start && sonarrQuery["end"] == end && sonarrQuery["includeSeries"] == "true")
    }
}

struct TorrentSummaryTests {
    @Test func theBusiestFiveAreActiveAndTheStatesAreTheServers() async throws {
        let (direct, transport) = backend(["qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080")])
        let torrents = (1 ... 7).map { i in
            #"{"hash": "h\#(i)", "name": "t\#(i)", "state": "\#(i == 7 ? "pausedUP" : "uploading")", "dlspeed": 0, "upspeed": \#(i == 7 ? 0 : i * 10), "progress": 1, "size": 1, "eta": 8640000, "tags": "a, b,", "tracker": "https://tracker.example.org/announce", "completion_on": \#(i == 7 ? -1 : 1_700_000_000)}"#
        }
        transport.on("GET /api/v2/torrents/info", json: "[\(torrents.joined(separator: ","))]")
        transport.on("GET /api/v2/transfer/info", json: #"{"dl_info_speed": 300, "up_info_speed": 210}"#)
        let summary = try #require(try await direct.torrentSummary()[.qbittorrent]?.value)
        #expect(summary.count == 7)
        #expect(summary.active_count == 6)
        #expect(summary.active?.map(\.id) == ["h6", "h5", "h4", "h3", "h2"])
        #expect(summary.totals.dl_speed == 300 && summary.totals.ul_speed == 210)
        let first = try #require(summary.active?.first)
        #expect(first.state == "seeding" && first.eta == nil && first.tags == ["a", "b"])
        #expect(first.tracker == "example.org" && first.completed_on == 1_700_000_000)
    }

    @Test func transmissionIsAskedForTheServersFieldsAndAnErrorWins() async throws {
        let (direct, transport) = backend(["transmission": ServiceConnection(url: "http://10.0.0.5:9091")])
        transport.on("POST /transmission/rpc") { request in
            let method = try body(request)["method"].string
            let text = method == "torrent-get"
                ? #"{"result": "success", "arguments": {"torrents": [{"id": 4, "name": "x", "status": 4, "rateDownload": 5, "rateUpload": 0, "errorString": "tracker gone", "eta": -1, "trackers": [{"announce": "udp://www.tracker.net:80"}]}]}}"#
                : #"{"result": "success", "arguments": {"downloadSpeed": 5, "uploadSpeed": 0}}"#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        let summary = try #require(try await direct.torrentSummary()[.transmission]?.value)
        let torrent = try #require(summary.active?.first)
        #expect(torrent.id == "4" && torrent.state == "error" && torrent.error == "tracker gone" && torrent.eta == nil)
        #expect(torrent.tracker == "tracker.net")
        #expect(try body(transport.requests.first)["arguments"]["fields"] == DashboardPort.transmissionFields)
    }

    @Test func speedsAreAveragedOverTheLastMinute() async throws {
        let (direct, transport) = backend(["qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080")])
        let speed = Locked(100)
        transport.on("GET /api/v2/torrents/info", json: "[]")
        transport.on("GET /api/v2/transfer/info") { _ in
            ServiceResponse(status: 200, headers: [:], data: Data(#"{"dl_info_speed": \#(speed.current), "up_info_speed": 0}"#.utf8))
        }
        _ = try await direct.torrentSummary()
        speed.withLock { $0 = 201 }
        let summary = try await direct.torrentSummary()[.qbittorrent]?.value
        #expect(summary?.totals.dl_speed == 150)
    }
}

struct ActivityTests {
    private let since = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    @Test func onlyWhatIsNewAndNotableIsCountedAndAnAlbumOnce() async throws {
        let (direct, transport) = backend([
            "sonarr": sonarr, "lidarr": lidarr, "qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080"),
        ])
        transport.on("GET /api/v3/history", json: """
        {"records": [
          {"eventType": "grabbed", "date": "2026-01-02T10:00:00Z", "sourceTitle": "Show.S01.1080p", "seriesId": 3,
           "episode": {"seasonNumber": 1, "episodeNumber": 2}},
          {"eventType": "downloadFolderImported", "date": "2025-12-31T10:00:00Z", "sourceTitle": "Old"},
          {"eventType": "episodeFileRenamed", "date": "2026-01-02T11:00:00Z", "sourceTitle": "Renamed"}
        ]}
        """)
        transport.on("GET /api/v1/history", json: """
        {"records": [
          {"eventType": "trackFileImported", "date": "2026-01-03T10:00:00Z", "downloadId": "abc", "albumId": 5,
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}},
          {"eventType": "trackFileImported", "date": "2026-01-03T10:00:01Z", "downloadId": "abc", "albumId": 5,
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}},
          {"eventType": "downloadImported", "date": "2026-01-03T10:00:02Z", "downloadId": "abc", "albumId": 5,
           "album": {"title": "Album"}, "artist": {"artistName": "Artist"}}
        ]}
        """)
        transport.on("GET /api/v2/torrents/info", json: """
        [{"name": "Done", "completion_on": 1767484800}, {"name": "Running", "completion_on": -1}]
        """)
        let activity = try await direct.activitySince(since)
        #expect(activity.count == 3)
        let items = try #require(activity.items)
        #expect(items.map(\.title) == ["Done", "Artist — Album", "Show.S01.1080p"])
        #expect(items.map(\.kind) == [.completed, .imported, .fetched])
        #expect(items[0].date == "2026-01-04T00:00:00Z")
        #expect(items[1].album_id == 5 && items[1].season == nil)
        #expect(items[2].season == 1 && items[2].episode == 2 && items[2].series_id == 3)
        #expect(activity.since == "2026-01-01T00:00:00Z")
        let sonarrQuery = query(transport.requests.first { $0.url?.port == 8989 })
        #expect(sonarrQuery["includeEpisode"] == "true" && sonarrQuery["pageSize"] == "100")
    }

    @Test func theCountIsEverythingThoughTheListStopsAt200() async throws {
        let (direct, transport) = backend(["qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080")])
        let torrents = (1 ... 250).map { #"{"name": "t\#($0)", "completion_on": \#(1_767_225_600 + $0)}"# }
        transport.on("GET /api/v2/torrents/info", json: "[\(torrents.joined(separator: ","))]")
        let activity = try await direct.activitySince(since)
        #expect(activity.count == 250)
        #expect(activity.items?.count == 200)
        #expect(activity.items?.first?.title == "t250")
    }
}

struct RecentTests {
    @Test func importsNewestFirstOnceATitle() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("GET /api/v3/movie", json: #"[{"id": 1, "title": "Film", "year": 2024, "images": []}]"#)
        transport.on("GET /api/v3/series", json: #"[{"id": 3, "title": "Show", "images": []}]"#)
        transport.on("GET /api/v3/history") { request in
            let text = request.url?.port == 7878
                ? #"{"records": [{"eventType": "downloadFolderImported", "movieId": 1, "date": "2026-01-01T00:00:00Z"}, {"eventType": "grabbed", "movieId": 1, "date": "2026-01-05T00:00:00Z"}]}"#
                : #"{"records": [{"eventType": "downloadFolderImported", "seriesId": 3, "date": "2026-01-03T00:00:00Z", "sourceTitle": "Show.s01e05.720p"}, {"eventType": "downloadFolderImported", "seriesId": 3, "date": "2026-01-02T00:00:00Z", "sourceTitle": "Show.S01E04"}]}"#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        let recent = try await direct.recent()
        #expect(recent.map(\.title) == ["Show", "Film"])
        #expect(recent.map(\.subtitle) == ["S01E05", "2024"])
    }
}

struct HealthTests {
    @Test func errorsComeFirstAndUpdateNoticesAreLeftOut() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("GET /api/v3/health") { request in
            let text = request.url?.port == 7878
                ? #"[{"source": "UpdateCheck", "type": "warning", "message": "new version"}, {"source": "IndexerStatusCheck", "type": "warning", "message": "indexers down", "wikiUrl": "https://wiki"}]"#
                : #"[{"source": "RootFolderCheck", "type": "error", "message": "missing root"}]"#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        transport.on("GET /api/v3/downloadclient") { request in
            let text = request.url?.port == 7878 ? #"[{"enable": false}]"# : #"[{"enable": true}]"#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        let warnings = try #require(try await direct.health().value)
        #expect(warnings.map(\.message) == ["no download client is enabled", "missing root", "indexers down"])
        #expect(warnings.map(\.app) == ["radarr", "sonarr", "radarr"])
        #expect(warnings.last?.wiki_url == "https://wiki")
    }

    @Test func unpackerrFailuresReadFromPrometheus() async throws {
        let (direct, transport) = backend(["prometheus": ServiceConnection(url: "http://10.0.0.5:9090")])
        transport.on("GET /api/v1/query") { request in
            let expression = query(request)["query"] ?? ""
            let result = switch expression {
            case "unpackerr_gauges": #"[{"metric": {"name": "failed"}, "value": [0, "2"]}]"#
            case let e where e.contains("fetch_errors"): #"[{"metric": {"app": "Sonarr"}, "value": [0, "4"]}, {"metric": {"app": "Radarr"}, "value": [0, "1"]}]"#
            default: #"[{"metric": {"name": "cmd_fail"}, "value": [0, "1.5"]}]"#
            }
            return ServiceResponse(status: 200, headers: [:], data: Data(#"{"status": "success", "data": {"result": \#(result)}}"#.utf8))
        }
        let warnings = try #require(try await direct.health().value)
        #expect(warnings.map(\.message) == [
            "2 extraction(s) failed", "1 cmd fail in the last hour", "cannot read Sonarr's queue (4 errors in the last hour)",
        ])
    }
}

struct RequestTests {
    @Test func aPendingRequestIsNamedFromTMDBAndItsPosterIsTheAppsSize() async throws {
        let (direct, transport) = backend(["overseerr": .arr("http://10.0.0.5:5055")])
        transport.on("GET /api/v1/request", json: """
        {"results": [
          {"id": 1, "type": "movie", "status": 1, "media": {"tmdbId": 603}, "requestedBy": {"displayName": "Ann"},
           "createdAt": "2026-01-01T00:00:00.000Z"},
          {"id": 2, "type": "tv", "status": 1, "media": {"tmdbId": 1399}, "seasons": [{"seasonNumber": 1}, {"seasonNumber": 0}]}
        ]}
        """)
        transport.on("GET /api/v1/movie/603", json: #"{"title": "The Matrix", "releaseDate": "1999-03-31", "posterPath": "/m.jpg"}"#)
        transport.on("GET /api/v1/tv/1399", status: 404, json: #"{"message": "not found"}"#)
        let requests = try #require(try await direct.pendingRequests().value)
        #expect(requests.map(\.id) == [1, 2])
        #expect(requests[0].title == "The Matrix" && requests[0].year == "1999" && requests[0].requested_by == "Ann")
        #expect(requests[0].poster == "https://image.tmdb.org/t/p/w500/m.jpg")
        #expect(requests[1].title == "" && requests[1].seasons == [1] && requests[1]._type == "tv")
        #expect(query(transport.requests.first)["filter"] == "pending")
    }
}

struct VpnTests {
    @Test func theForwardedPortIsCheckedAgainstQbittorrents() async throws {
        let (direct, transport) = backend([
            "gluetun": .arr("http://10.0.0.5:8000"), "qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080"),
        ])
        transport.on("GET /v1/vpn/status", json: #"{"status": "running"}"#)
        transport.on("GET /v1/publicip/ip", json: #"{"public_ip": "1.2.3.4", "country": "Sweden"}"#)
        transport.on("GET /v1/portforward", json: #"{"port": 51413}"#)
        transport.on("GET /api/v2/app/preferences", json: #"{"listen_port": 6881}"#)
        let vpn = try #require(try await direct.vpn().value)
        #expect(vpn.status == "running" && vpn.public_ip == "1.2.3.4" && vpn.country == "Sweden")
        #expect(vpn.forwarded_port == 51413 && vpn.client_port == 6881 && vpn.port_matches == false)
    }
}

struct PlexSessionTests {
    @Test func anEpisodeIsNamedForItsShowWithItsCode() throws {
        let item = try json("""
        {"type": "episode", "grandparentTitle": "Show", "title": "Pilot", "parentIndex": 1, "index": 2,
         "duration": 1000, "viewOffset": 250, "ratingKey": "77", "User": {"title": "ann"},
         "Player": {"title": "TV", "state": "playing"}, "TranscodeSession": {"key": "x"}}
        """)
        let session = DashboardCards.playSession(machine: "m1", item: item)
        #expect(session.title == "Show" && session.subtitle == "S01E02 – Pilot" && session.progress == 0.25)
        #expect(session.transcoding == true && session.user == "ann" && session.state == "playing")
        #expect(session.url == "https://app.plex.tv/desktop/#!/server/m1/details?key=/library/metadata/77")
        let untitled = DashboardCards.playSession(machine: "", item: item.setting("title", ""))
        #expect(untitled.subtitle == "S01E02" && untitled.url == nil)
    }
}

struct QueueActionTests {
    @Test func forceImportImportsOnlyWhatTheArrPlaced() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 4, "downloadId": "HASH", "movieId": 10}]}"#)
        transport.on("GET /api/v3/manualimport", json: """
        [{"path": "/d/film.mkv", "quality": {"quality": {"id": 3}}, "movie": {"id": 10}, "languages": [{"id": 1}],
          "releaseGroup": "GRP"},
         {"path": "/d/sample.mkv", "quality": {"quality": {"id": 3}}, "movie": {}}]
        """)
        transport.on("POST /api/v3/command", json: #"{"id": 1}"#)
        try await direct.forceImport(app: .radarr, id: 4)
        let command = try body(transport.requests.last)
        #expect(command["name"] == "ManualImport" && command["importMode"] == "auto")
        #expect(command["files"] == [[
            "path": "/d/film.mkv", "quality": ["quality": ["id": 3]], "languages": [["id": 1]],
            "releaseGroup": "GRP", "downloadId": "HASH", "movieId": 10,
        ]])
        #expect(query(transport.requests.first { $0.url?.path().hasSuffix("manualimport") == true })["downloadId"] == "HASH")
    }

    @Test func forceImportWithNothingPlacedSaysSo() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 4, "downloadId": "HASH"}]}"#)
        transport.on("GET /api/v3/manualimport", json: #"[{"path": "/d/x.mkv", "quality": {}, "movie": {"id": 10}}]"#)
        await #expect(throws: APIError.refused("no importable files could be mapped automatically")) {
            try await direct.forceImport(app: .radarr, id: 4)
        }
        await #expect(throws: APIError.refused("queue item not found")) {
            try await direct.forceImport(app: .radarr, id: 5)
        }
    }

    @Test func blocklistAndRetryRemovesTheItemAndLooksForTheEpisodeAgain() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 7, "episodeId": 9, "seriesId": 3}]}"#)
        transport.on("DELETE /api/v3/queue/7", json: "")
        transport.on("POST /api/v3/command", json: #"{"id": 2}"#)
        try await direct.blocklistRetry(app: .sonarr, id: 7)
        let delete = try #require(transport.requests.first { $0.httpMethod == "DELETE" })
        #expect(query(delete) == ["removeFromClient": "true", "blocklist": "true"])
        #expect(try body(transport.requests.last) == ["name": "EpisodeSearch", "episodeIds": [9]])
    }
}

struct BlocklistTests {
    @Test func lidarrIsClearedIdByIdAcrossItsPages() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("GET /api/v1/blocklist") { request in
            let text = query(request)["page"] == "1"
                ? #"{"totalRecords": 3, "records": [{"id": 1}, {"id": 2}]}"#
                : #"{"totalRecords": 3, "records": [{"id": 3}]}"#
            return ServiceResponse(status: 200, headers: [:], data: Data(text.utf8))
        }
        transport.on("DELETE /api/v1/blocklist/bulk", json: "")
        try await direct.clearBlocklist(.lidarr)
        #expect(try body(transport.requests.last) == ["ids": [1, 2, 3]])
        #expect(query(transport.requests.first)["pageSize"] == "1000")
    }

    @Test func readarrKeepsNoBlocklistHere() async throws {
        let (direct, _) = backend(["readarr": .arr("http://10.0.0.5:8787")])
        await #expect(throws: APIError.refused("unknown app 'readarr'")) {
            try await direct.removeFromBlocklist(.readarr, id: 1)
        }
    }

    @Test func theListIsMergedNewestFirstAndADownArrIsLeftOut() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("GET /api/v3/blocklist") { request in
            guard request.url?.port == 7878 else { return ServiceResponse(status: 503, headers: [:], data: Data()) }
            return ServiceResponse(status: 200, headers: [:], data: Data(#"""
            {"totalRecords": 2, "records": [
              {"id": 1, "movie": {"title": "Film"}, "sourceTitle": "Film.2024", "date": "2026-01-01T00:00:00Z",
               "quality": {"quality": {"name": "Bluray-1080p"}}, "indexer": "Idx"},
              {"id": 2, "movie": {"title": "Later"}, "sourceTitle": "Later.2025", "date": "2026-02-01T00:00:00Z"}
            ]}
            """#.utf8))
        }
        let page = try await direct.blocklist()
        #expect(page.total == 2)
        #expect(page.items?.map(\.title) == ["Later", "Film"])
        #expect(page.items?.last?.quality == "Bluray-1080p" && page.items?.last?.source_title == "Film.2024")
    }
}

struct SubtitleTests {
    @Test func anEpisodeSearchIsAFormPatchToBazarr() async throws {
        let (direct, transport) = backend(["bazarr": .arr("http://10.0.0.5:6767")])
        transport.on("PATCH /api/episodes", json: "")
        try await direct.searchSubtitles(kind: .episode, id: 9, seriesID: 3)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-KEY") == "secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "action=search-missing&episodeid=9&seriesid=3")
    }

    @Test func theCountsAreBazarrsBadgesAndMoviesComeFirst() async throws {
        let (direct, transport) = backend(["bazarr": .arr("http://10.0.0.5:6767")])
        transport.on("GET /api/badges", json: #"{"episodes": 12, "movies": 3, "providers": 1}"#)
        transport.on("GET /api/episodes/wanted", json: """
        {"data": [{"sonarrEpisodeId": 9, "sonarrSeriesId": 3, "seriesTitle": "Show", "episode_number": "1x02",
                   "episodeTitle": "Pilot", "missing_subtitles": [{"name": "Danish"}]}]}
        """)
        transport.on("GET /api/movies/wanted", json: #"{"data": [{"radarrId": 4, "title": "Film", "missing_subtitles": []}]}"#)
        let subtitles = try #require(try await direct.subtitles().value)
        #expect(subtitles.episodes == 12 && subtitles.movies == 3 && subtitles.throttled_providers == 1)
        #expect(subtitles.items?.map(\.kind) == ["movie", "episode"])
        #expect(subtitles.items?.last?.subtitle == "1x02 Pilot" && subtitles.items?.last?.missing == ["Danish"])
    }
}
