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

/// Radarr and Sonarr share their paths: the answer goes by the port asked.
/// An arr without one refuses the key, which is not retried.
private func byPort(_ answers: [Int: String]) -> StubTransport.Handler {
    { request in
        guard let json = answers[request.url?.port ?? 0] else {
            return ServiceResponse(status: 401, headers: [:], data: Data())
        }
        return ok(json)
    }
}

private func sent(_ transport: StubTransport, _ method: String, _ suffix: String) -> [URLRequest] {
    transport.requests.filter { $0.httpMethod == method && ($0.url?.path() ?? "").hasSuffix(suffix) }
}

private let radarr = ServiceConnection.arr("http://10.0.0.5:7878")
private let sonarr = ServiceConnection.arr("http://10.0.0.5:8989")
private let readarr = ServiceConnection.arr("http://10.0.0.5:8787")
private let lidarr = ServiceConnection.arr("http://10.0.0.5:8686")
private let qbittorrent = ServiceConnection(url: "http://10.0.0.5:8080")
private let transmission = ServiceConnection(url: "http://10.0.0.5:9091")
private let plex = ServiceConnection.arr("http://10.0.0.5:32400", key: "token")
private let overseerr = ServiceConnection.arr("http://10.0.0.5:5055")
private let hash = "0123456789abcdef0123456789abcdef01234567"

struct ImportCleanupAttentionTests {
    @Test func stuckItemsAcrossTheArrsSetUpWithTheDownOnesNamed() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr, "lidarr": lidarr])
        transport.on("GET /api/v3/queue", byPort([7878: """
        {"records": [{"id": 1, "title": "A", "trackedDownloadState": "importBlocked"},
                     {"id": 2, "title": "B", "trackedDownloadState": "downloading"}]}
        """]))
        transport.on("GET /api/v1/queue", json: #"{"records": [{"id": 3, "title": "C", "trackedDownloadStatus": "warning"}]}"#)
        let attention = try await direct.attention()
        #expect(attention.items?.map(\.id) == [1, 3])
        #expect(attention.count == 2)
        // Readarr was never set up: absent, not unavailable
        #expect(attention.unavailable == ["sonarr"])
    }
}

struct ImportCleanupCandidateTests {
    @Test func aQueueItemsFilesWithTheArrsReasons() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 5, "downloadId": "ABC"}]}"#)
        transport.on("GET /api/v3/manualimport", json: """
        [{"path": "/dl/Show/S01E02.mkv", "size": 1000, "quality": {"quality": {"id": 4, "name": "HDTV-720p"}},
          "languages": [{"id": 1, "name": "English"}, {"name": "Weird"}], "series": {"id": 3, "title": "Show"},
          "episodes": [{"id": 10, "seasonNumber": 1, "episodeNumber": 2}, {"id": 11, "seasonNumber": 1, "episodeNumber": 3}],
          "rejections": [{"reason": "Not an upgrade", "type": "permanent"}, "plain"]},
         {"path": "/dl/Show/sample.mkv", "name": "", "quality": null, "series": {}, "rejections": [{"reason": "Sample"}]}]
        """)
        let candidates = try await direct.importCandidates(.queue(app: .sonarr, itemID: 5))
        #expect(query(sent(transport, "GET", "/manualimport")[0]) == ["downloadId": "ABC", "filterExistingFiles": "false"])
        let matched = candidates[0]
        #expect(matched.title == "Show")
        #expect(matched.subtitle == "S01E02 +1")
        #expect(matched.importable == true)
        #expect(matched.languages == ["English", "Weird"])
        #expect(matched.language_ids == [1])
        #expect(matched.rejections == ["Not an upgrade", "plain"])
        #expect(matched.name == "S01E02.mkv")
        #expect(matched.quality == "HDTV-720p")
        #expect(matched.quality_id == 4)
        #expect(matched.size == 1000)
        let sample = candidates[1]
        #expect(sample.importable == false)
        #expect(sample.name == "sample.mkv")
        #expect(sample.title == "")
        #expect(sample.subtitle == nil)
        #expect(sample.rejections == ["Sample"])
    }

    @Test func anAlbumReadsInTrackOrderWithItsTracksNamed() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("GET /api/v1/queue", json: #"{"records": [{"id": 3, "downloadId": "L"}]}"#)
        transport.on("GET /api/v1/manualimport", json: """
        [{"path": "/m/02.flac", "artist": {"artistName": "Artist"}, "album": {"title": "Album"},
          "tracks": [{"absoluteTrackNumber": 2, "title": "Two"}, {"title": "Hidden"}]},
         {"path": "/m/01.flac", "artist": {"artistName": "Artist"}, "album": {"title": "Album"},
          "tracks": [{"trackNumber": "1", "title": "Intro"}]}]
        """)
        let candidates = try await direct.importCandidates(.queue(app: .lidarr, itemID: 3))
        #expect(candidates.map(\.path) == ["/m/01.flac", "/m/02.flac"])
        #expect(candidates.map(\.subtitle) == ["Artist · 1. Intro", "Artist · 2. Two +1"])
        #expect(candidates.allSatisfy { $0.title == "Album" && $0.importable == false })
    }

    @Test func anItemWithoutADownloadIsNotFound() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 5}]}"#)
        await #expect(throws: APIError.refused("queue item not found")) {
            try await direct.importCandidates(.queue(app: .radarr, itemID: 5))
        }
    }
}

struct ImportCleanupRunTests {
    @Test func pickedFilesGoInOnTheArrsOwnMatchTiedToTheDownload() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 5, "downloadId": "ABC"}]}"#)
        transport.on("GET /api/v3/manualimport", json: """
        [{"path": "/dl/a.mkv", "quality": {"quality": {"id": 1}}, "languages": [{"id": 1, "name": "English"}],
          "releaseGroup": "G", "series": {"id": 3}, "episodes": [{"id": 10}]},
         {"path": "/dl/b.mkv", "quality": {"quality": {"id": 1}}, "series": {"id": 3}, "episodes": [{"id": 11}]}]
        """)
        transport.on("POST /api/v3/command", json: #"{"id": 99, "status": "queued"}"#)
        let command = try await direct.startImport(.plain(.sonarr, .init(item_id: 5, paths: ["/dl/a.mkv"])))
        #expect(command == ImportCommand(app: "sonarr", done: false, id: 99, message: nil, status: "queued"))
        let payload = body(sent(transport, "POST", "/command")[0])
        #expect(payload["name"] == "ManualImport")
        #expect(payload["importMode"] == "auto")
        #expect(payload["files"] == [[
            "path": "/dl/a.mkv", "quality": ["quality": ["id": 1]], "languages": [["id": 1, "name": "English"]],
            "releaseGroup": "G", "downloadId": "ABC", "seriesId": 3, "episodeIds": [10],
        ]])
    }

    @Test func nothingMappedIsRefusedBeforeTheArrIsAsked() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 5, "downloadId": "ABC"}]}"#)
        transport.on("GET /api/v3/manualimport", json: #"[{"path": "/dl/a.mkv", "quality": {"quality": {"id": 1}}}]"#)
        await #expect(throws: APIError.refused("none of the selected files could be mapped")) {
            try await direct.startImport(.plain(.radarr, .init(item_id: 5, paths: ["/dl/a.mkv"])))
        }
        #expect(sent(transport, "POST", "/command").isEmpty)
    }

    private static func assigning(_ transport: StubTransport) {
        transport.on("GET /api/v3/queue", json: #"{"records": [{"id": 1, "downloadId": "D1"}]}"#)
        transport.on("GET /api/v3/manualimport", json: """
        [{"path": "/dl/m.mkv", "releaseGroup": "",
          "quality": {"quality": {"id": 1, "name": "SDTV"}, "revision": {"version": 2, "real": 0, "isRepack": true}},
          "languages": [{"id": 1, "name": "English"}]}]
        """)
        transport.on("GET /api/v3/qualitydefinition", json: """
        [{"quality": {"id": 4, "name": "WEBDL-1080p", "source": "web", "resolution": 1080}}, {"quality": {"id": 1, "name": "SDTV"}}]
        """)
        transport.on("GET /api/v3/language", json: #"[{"id": -1, "name": "Any"}, {"id": 2, "name": "French"}, {"id": 1, "name": "English"}]"#)
        transport.on("POST /api/v3/command", json: """
        {"id": 7, "status": "completed", "result": "successful", "message": "Manually imported 1 file"}
        """)
    }

    @Test func aHandPickedFilmWithACorrectedQualityKeepsItsRevision() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        Self.assigning(transport)
        let file = ImportFile(language_ids: [2], movie_id: 42, path: "/dl/m.mkv", quality_id: 4)
        let command = try await direct.startImport(.assign(.radarr, .init(files: [file], item_id: 1, mode: .copy)))
        #expect(command.done == true)
        #expect(command.ok == true)
        #expect(command.imported == 1)
        let payload = body(sent(transport, "POST", "/command")[0])
        #expect(payload["importMode"] == "copy")
        #expect(payload["files"] == [[
            "path": "/dl/m.mkv", "releaseGroup": "", "downloadId": "D1", "movieId": 42,
            "quality": [
                "quality": ["id": 4, "name": "WEBDL-1080p", "source": "web", "resolution": 1080],
                "revision": ["version": 2, "real": 0, "isRepack": true],
            ],
            "languages": [["id": 2, "name": "French"]],
        ]])
    }

    @Test func theOptionsAreTheQualitiesInOrderAndRealLanguagesByName() async throws {
        let (direct, transport) = backend(["radarr": radarr, "readarr": readarr])
        Self.assigning(transport)
        transport.on("GET /api/v1/qualitydefinition", json: #"[{"quality": {"id": 1, "name": "EPUB"}}, {"quality": null}]"#)
        let options = try await direct.importOptions(.radarr)
        #expect(options.qualities == [ImportChoice(id: 4, name: "WEBDL-1080p"), ImportChoice(id: 1, name: "SDTV")])
        #expect(options.languages == [ImportChoice(id: 1, name: "English"), ImportChoice(id: 2, name: "French")])
        // Readarr's files carry no language: nothing to ask for
        let books = try await direct.importOptions(.readarr)
        #expect(books.qualities == [ImportChoice(id: 1, name: "EPUB")])
        #expect(books.languages == [])
        #expect(sent(transport, "GET", "/api/v1/language").isEmpty)
    }

    @Test func choicesTheArrDidNotOfferAreRefused() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        Self.assigning(transport)
        func assign(_ file: ImportFile) async throws {
            _ = try await direct.startImport(.assign(.radarr, .init(files: [file], item_id: 1)))
        }
        await #expect(throws: APIError.refused("no candidate for '/dl/other.mkv'")) {
            try await assign(ImportFile(movie_id: 42, path: "/dl/other.mkv"))
        }
        await #expect(throws: APIError.refused("a movie must be chosen for each file")) {
            try await assign(ImportFile(path: "/dl/m.mkv"))
        }
        await #expect(throws: APIError.refused("unknown quality id 9")) {
            try await assign(ImportFile(movie_id: 42, path: "/dl/m.mkv", quality_id: 9))
        }
        await #expect(throws: APIError.refused("unknown language ids [-1, 3]")) {
            try await assign(ImportFile(language_ids: [-1, 2, 3], movie_id: 42, path: "/dl/m.mkv"))
        }
        #expect(sent(transport, "POST", "/command").isEmpty)
    }

    @Test func aPickedBookGoesToItsMonitoredEdition() async throws {
        let (direct, transport) = backend(["readarr": readarr])
        transport.on("GET /api/v1/queue", json: #"{"records": [{"id": 2, "downloadId": "R"}]}"#)
        transport.on("GET /api/v1/manualimport", json: #"[{"path": "/dl/b.epub", "quality": {"quality": {"id": 1}}}]"#)
        transport.on("GET /api/v1/book/55", json: #"{"id": 55, "authorId": 9}"#)
        transport.on("GET /api/v1/edition", json: """
        [{"monitored": false, "foreignEditionId": "x"}, {"monitored": true, "foreignEditionId": "E1"}]
        """)
        transport.on("POST /api/v1/command", json: #"{"id": 1}"#)
        _ = try await direct.startImport(.assign(.readarr, .init(files: [ImportFile(book_id: 55, path: "/dl/b.epub")], item_id: 2)))
        #expect(query(sent(transport, "GET", "/edition")[0]) == ["bookId": "55"])
        #expect(body(sent(transport, "POST", "/command")[0])["files"] == [[
            "path": "/dl/b.epub", "quality": ["quality": ["id": 1]], "indexerFlags": 0, "downloadId": "R",
            "authorId": 9, "bookId": 55, "foreignEditionId": "E1",
        ]])
    }

    @Test func filesPickedForAnAlbumAreMatchedToItsTracksByLidarr() async throws {
        let (direct, transport) = backend(["lidarr": lidarr])
        transport.on("GET /api/v1/queue", json: #"{"records": [{"id": 3, "downloadId": "L"}]}"#)
        transport.on("GET /api/v1/manualimport", json: """
        [{"id": 100, "path": "/dl/02.flac", "quality": {"quality": {"id": 6}}},
         {"id": 101, "path": "/dl/01.flac", "quality": {"quality": {"id": 6}}, "indexerFlags": 2}]
        """)
        transport.on("GET /api/v1/album/77", json: """
        {"id": 77, "artistId": 5, "title": "Album", "releases": [{"id": 800, "monitored": false}, {"id": 801, "monitored": true}]}
        """)
        transport.on("POST /api/v1/manualimport", json: """
        [{"path": "/dl/01.flac", "artist": {"id": 5}, "album": {"id": 77}, "albumReleaseId": 802, "tracks": [{"id": 1}]},
         {"path": "/dl/02.flac", "artist": {"id": 5}, "album": {"id": 77}, "albumReleaseId": 802, "tracks": [{"id": 2}]}]
        """)
        transport.on("POST /api/v1/command", json: #"{"id": 3, "status": "started"}"#)
        let files = [ImportFile(album_id: 77, path: "/dl/02.flac"), ImportFile(album_id: 77, path: "/dl/01.flac")]
        let command = try await direct.startImport(.assign(.lidarr, .init(files: files, item_id: 3)))
        #expect(command.done == false)
        #expect(body(sent(transport, "POST", "/manualimport")[0]) == [
            ["id": 100, "path": "/dl/02.flac", "artistId": 5, "albumId": 77, "albumReleaseId": 801,
             "quality": ["quality": ["id": 6]], "indexerFlags": 0, "disableReleaseSwitching": false, "downloadId": "L"],
            ["id": 101, "path": "/dl/01.flac", "artistId": 5, "albumId": 77, "albumReleaseId": 801,
             "quality": ["quality": ["id": 6]], "indexerFlags": 2, "disableReleaseSwitching": false, "downloadId": "L"],
        ])
        let sentFiles = body(sent(transport, "POST", "/command")[0])["files"].array
        // Lidarr settled on another release of the album; that is the one imported into
        #expect(sentFiles.map { $0["trackIds"] } == [[2], [1]])
        #expect(sentFiles.allSatisfy { $0["albumReleaseId"] == 802 && $0["artistId"] == 5 && $0["albumId"] == 77 })
        #expect(sentFiles.map { $0["indexerFlags"] } == [0, 2])
    }

    @Test func aCrashedImportShowsTheFirstLineOfTheArrsError() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/command/12", json: """
        {"id": 12, "status": "failed", "message": "Failed",
         "exception": "\\n  System.IO.IOException: Disk full\\n   at Foo.Bar()\\n"}
        """)
        let command = try await direct.importCommand(app: .radarr, id: 12)
        #expect(command == ImportCommand(
            app: "radarr", done: true, id: 12, imported: nil, message: "System.IO.IOException: Disk full", ok: false,
            status: "failed"
        ))
    }
}

struct ImportCleanupTorrentTests {
    private static func finished(_ transport: StubTransport, root: String = "/downloads/Film.2020", progress: Double = 1) {
        transport.on("GET /api/v2/torrents/info", json: """
        [{"hash": "\(hash)", "progress": \(progress), "save_path": "/downloads", "root_path": "\(root)", "name": "Film.2020"}]
        """)
    }

    @Test func aFinishedTorrentIsCopiedSoItKeepsSeeding() async throws {
        let (direct, transport) = backend(["radarr": radarr, "qbittorrent": qbittorrent])
        Self.finished(transport)
        transport.on("GET /api/v3/queue", json: #"{"records": [{"downloadId": "somethingelse"}]}"#)
        transport.on("GET /api/v3/manualimport", json: """
        [{"path": "/downloads/Film.2020/f.mkv", "quality": {"quality": {"id": 1}}, "movie": {"id": 8}}]
        """)
        transport.on("POST /api/v3/command", json: #"{"id": 4, "status": "queued"}"#)
        _ = try await direct.startImport(.torrent(.radarr, .init(
            client: .qbittorrent, files: [ImportFile(path: "/downloads/Film.2020/f.mkv")], torrent_id: hash
        )))
        #expect(query(sent(transport, "GET", "/api/v2/torrents/info")[0]) == ["hashes": hash])
        #expect(query(sent(transport, "GET", "/manualimport")[0]) == ["folder": "/downloads/Film.2020", "filterExistingFiles": "false"])
        let payload = body(sent(transport, "POST", "/command")[0])
        #expect(payload["importMode"] == "copy")
        // no tracked download to name
        #expect(payload["files"] == [[
            "path": "/downloads/Film.2020/f.mkv", "quality": ["quality": ["id": 1]], "languages": [], "releaseGroup": "",
            "movieId": 8,
        ]])
    }

    @Test func aDownloadAnArrTracksGoesToItsQueueItemInstead() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr, "qbittorrent": qbittorrent])
        Self.finished(transport)
        transport.on("GET /api/v3/queue", byPort([7878: #"{"records": []}"#, 8989: """
        {"records": [{"downloadId": "\(hash.uppercased())"}]}
        """]))
        await #expect(throws: APIError.refused(
            "Sonarr is already tracking this download; fix it from its queue item (Needs attention) instead"
        )) {
            try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: hash))
        }
    }

    @Test func aFolderTheArrCannotSeeIsSaidNotGuessed() async throws {
        let (direct, transport) = backend(["radarr": radarr, "qbittorrent": qbittorrent])
        Self.finished(transport)
        transport.on("GET /api/v3/queue", json: #"{"records": []}"#)
        transport.on("GET /api/v3/manualimport", json: "[]")
        transport.on("GET /api/v3/filesystem", json: #"{"directories": [{"name": "Other"}], "files": []}"#)
        await #expect(throws: APIError.refused(
            "Radarr can't see /downloads/Film.2020: qBittorrent saved it to a folder that isn't mounted at the same "
                + "path in Radarr. Mount it there, or add a remote path mapping in Radarr."
        )) {
            try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: hash))
        }
        #expect(query(sent(transport, "GET", "/filesystem")[0]) == ["path": "/downloads/", "includeFiles": "true"])
        // seen there, it is simply empty
        transport.on("GET /api/v3/filesystem", json: #"{"directories": [{"name": "Film.2020"}], "files": []}"#)
        #expect(try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: hash)) == [])
    }

    @Test func onlyAFinishedTorrentInsideItsSavePathIsOffered() async throws {
        let (direct, transport) = backend(["radarr": radarr, "qbittorrent": qbittorrent])
        Self.finished(transport, root: "/downloads/../etc")
        await #expect(throws: APIError.refused("'/downloads/../etc' is not inside the torrent's save path '/downloads'")) {
            try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: hash))
        }
        Self.finished(transport, progress: 0.5)
        await #expect(throws: APIError.refused("the torrent has not finished downloading")) {
            try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: hash))
        }
        let asked = transport.requests.count
        await #expect(throws: APIError.refused("torrent not found")) {
            try await direct.importCandidates(.torrent(app: .radarr, client: .qbittorrent, torrentID: "../../x"))
        }
        // anything but a hash never reaches the torrent client
        #expect(transport.requests.count == asked)
    }

    @Test func transmissionIsAskedByItsOwnID() async throws {
        let (direct, transport) = backend(["sonarr": sonarr, "transmission": transmission])
        transport.on("POST /transmission/rpc", json: """
        {"result": "success", "arguments": {"torrents": [{"hashString": "", "percentDone": 1, "downloadDir": "/dl", "name": "Show"}]}}
        """)
        transport.on("GET /api/v3/manualimport", json: #"[{"path": "/dl/Show/e.mkv"}]"#)
        let candidates = try await direct.importCandidates(.torrent(app: .sonarr, client: .transmission, torrentID: "12"))
        #expect(candidates.map(\.path) == ["/dl/Show/e.mkv"])
        #expect(body(sent(transport, "POST", "/transmission/rpc")[0])["arguments"]["ids"] == [12])
        #expect(query(sent(transport, "GET", "/manualimport")[0])["folder"] == "/dl/Show")
        // no hash, so no queue to look it up in
        #expect(sent(transport, "GET", "/queue").isEmpty)
    }

    @Test func pathsAreReadTheWayPosixpathReadThem() throws {
        #expect(ManualImportPort.normpath("/a/./b/../c/") == "/a/c")
        #expect(ManualImportPort.normpath("//a") == "//a")
        #expect(ManualImportPort.normpath("///a") == "/a")
        #expect(ManualImportPort.normpath("") == ".")
        #expect(ManualImportPort.normpath("a/../..") == "..")
        #expect(ManualImportPort.normpath("/..") == "/")
        #expect(ManualImportPort.join("/dl", "x") == "/dl/x")
        #expect(ManualImportPort.join("/dl/", "") == "/dl/")
        #expect(ManualImportPort.split("/dl/x").head == "/dl")
        #expect(ManualImportPort.split("/x") == ("/", "x"))
        #expect(throws: APIError.self) { try ManualImportPort.inside("/dl", "/dl") }
        #expect(throws: APIError.self) { try ManualImportPort.inside("/dl", "/dlx/a") }
        #expect(try ManualImportPort.inside("/dl/", "/dl//a/") == "/dl/a")
    }
}

struct ImportCleanupListTests {
    private static func library(_ transport: StubTransport, now: Int) {
        transport.on("GET /api/v3/movie", json: """
        [{"id": 1, "title": "Old", "year": 2001, "sizeOnDisk": 500, "monitored": true, "tmdbId": 11, "imdbId": "tt1",
          "added": "2020-01-01T00:00:00Z",
          "images": [{"coverType": "poster", "url": "/MediaCover/1/poster.jpg", "remoteUrl": "https://image.tmdb.org/t/p/original/p.jpg"}]},
         {"id": 2, "title": "Empty", "sizeOnDisk": 0, "tmdbId": 12},
         {"id": 3, "title": "Unmonitored", "sizeOnDisk": 900, "monitored": false, "tmdbId": 13, "added": "2020-01-01T00:00:00Z"}]
        """)
        transport.on("GET /api/v3/series", json: """
        [{"id": 4, "title": "Show", "tvdbId": 44, "monitored": true, "added": "2020-01-01T00:00:00Z",
          "statistics": {"sizeOnDisk": 700},
          "seasons": [{"seasonNumber": 2, "monitored": true, "statistics": {"sizeOnDisk": 300, "episodeFileCount": 3}},
                      {"seasonNumber": 1, "monitored": false, "statistics": {"sizeOnDisk": 400, "episodeFileCount": 4}},
                      {"seasonNumber": 0, "statistics": {"sizeOnDisk": 0}}]}]
        """)
        transport.on("GET /identity", json: #"{"MediaContainer": {"machineIdentifier": "abc"}}"#)
        transport.on("GET /library/sections", json: """
        {"MediaContainer": {"Directory": [{"key": "1", "type": "movie"}, {"key": "2", "type": "show"}]}}
        """)
        transport.on("GET /library/sections/1/all", json: """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "r1", "viewCount": 1, "lastViewedAt": 1000000000, "Guid": [{"id": "tmdb://11"}]},
          {"ratingKey": "r3", "viewCount": 0, "Guid": [{"id": "tmdb://13"}]}]}}
        """)
        transport.on("GET /library/sections/2/all", json: """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "r4", "leafCount": 10, "viewedLeafCount": 10, "lastViewedAt": \(now - 86_400), "Guid": [{"id": "tvdb://44"}]}]}}
        """)
    }

    @Test func fourListsOverTheFilmsAndShows() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr, "plex": plex])
        let now = Int(Date.now.timeIntervalSince1970)
        Self.library(transport, now: now)
        let lists = try await direct.cleanup(watchedDays: 30)
        #expect(lists.plex == true)
        // watched long ago; the show was seen yesterday
        #expect(lists.watched?.map(\.id) == [1])
        #expect(lists.watched?.first?.last_viewed_at == 1_000_000_000)
        // in Plex, never played, added over a year ago
        #expect(lists.never_watched?.map(\.id) == [3])
        // nothing on disk is in no list
        #expect(lists.largest?.map(\.id) == [3, 4, 1])
        #expect(lists.unmonitored?.map(\.id) == [3])
        let old = try #require(lists.watched?.first)
        #expect(old.poster == "https://image.tmdb.org/t/p/w500/p.jpg")
        #expect(old.kind == .movie)
        #expect(old.size == 500)
        #expect(old.added == JSON.parseDate("2020-01-01T00:00:00Z"))
        let show = try #require(lists.largest?.first { $0.id == 4 })
        #expect(show.kind == .series)
        #expect(show.last_viewed_at == now - 86_400)
        #expect(show.seasons?.map(\.number) == [1, 2])
        #expect(show.seasons?.first == .init(files: 4, monitored: false, number: 1, size: 400))
    }

    @Test func withoutPlexTheWatchListsStayEmpty() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        Self.library(transport, now: Int(Date.now.timeIntervalSince1970))
        let lists = try await direct.cleanup(watchedDays: 30)
        #expect(lists.plex == false)
        #expect(lists.watched == [])
        #expect(lists.never_watched == [])
        #expect(lists.largest?.map(\.id) == [3, 1])
        // Sonarr was never set up, and is not asked
        #expect(sent(transport, "GET", "/series").isEmpty)
    }

    @Test func aDeleteCanKeepTheListsFromAddingThemBack() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr])
        transport.on("DELETE /api/v3/movie/editor", json: "")
        transport.on("DELETE /api/v3/series/editor", json: "")
        try await direct.deleteForCleanup(.radarr, ids: [1, 2], exclude: true)
        try await direct.deleteForCleanup(.sonarr, ids: [4], exclude: false)
        #expect(body(sent(transport, "DELETE", "/movie/editor")[0]) == [
            "movieIds": [1, 2], "deleteFiles": true, "addImportExclusion": true,
        ])
        #expect(body(sent(transport, "DELETE", "/series/editor")[0]) == [
            "seriesIds": [4], "deleteFiles": true, "addImportListExclusion": false,
        ])
    }

    @Test func someSeasonsAreUnmonitoredThenTheirFilesDeleted() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/series/4", json: """
        {"id": 4, "title": "Show", "seasons": [{"seasonNumber": 1, "monitored": true}, {"seasonNumber": 2, "monitored": true}]}
        """)
        transport.on("PUT /api/v3/series/4", json: "{}")
        transport.on("GET /api/v3/episodefile", json: """
        [{"id": 100, "seasonNumber": 1}, {"id": 101, "seasonNumber": 2}, {"id": 102, "seasonNumber": 1}]
        """)
        transport.on("DELETE /api/v3/episodefile/bulk", json: "")
        try await direct.removeSeasons(series: 4, seasons: [1])
        #expect(body(sent(transport, "PUT", "/series/4")[0])["seasons"] == [
            ["seasonNumber": 1, "monitored": false], ["seasonNumber": 2, "monitored": true],
        ])
        #expect(query(sent(transport, "GET", "/episodefile")[0]) == ["seriesId": "4"])
        #expect(body(sent(transport, "DELETE", "/episodefile/bulk")[0]) == ["episodeFileIds": [100, 102]])
        // the unmonitoring comes first, so an RSS sync cannot grab them back
        let order = transport.requests.map { $0.httpMethod ?? "" }
        #expect(order == ["GET", "PUT", "GET", "DELETE"])
        await #expect(throws: APIError.unexpectedStatus(422)) { try await direct.removeSeasons(series: 4, seasons: []) }
    }

    @Test func openRequestsKeyedForTheLibrary() async throws {
        let (direct, transport) = backend(["overseerr": overseerr])
        transport.on("GET /api/v1/request") { request in
            #expect(query(request)["take"] == "100")
            return query(request)["filter"] == "pending" ? ok("""
            {"results": [{"id": 1, "status": 1, "type": "movie", "media": {"tmdbId": 100}, "requestedBy": {"displayName": "Ann"}},
                         {"id": 2, "status": 1, "type": "tv", "media": {"tmdbId": 200, "tvdbId": 300}}]}
            """) : ok("""
            {"results": [{"id": 3, "status": 2, "type": "movie", "media": {"tmdbId": 100}},
                         {"id": 4, "status": 2, "media": {"mediaType": "tv", "tmdbId": 400}}]}
            """)
        }
        let map = try await direct.requestMap()
        #expect(Set(map.keys) == ["movie:tmdb:100", "tv:tmdb:200", "tv:tvdb:300", "tv:tmdb:400"])
        // the pending request is the one a title's badge shows
        #expect(map["movie:tmdb:100"] == RequestState(request_id: 1, requested_by: "Ann", status: 1))
        #expect(map["tv:tvdb:300"] == RequestState(request_id: 2, requested_by: "", status: 1))
        #expect(map["tv:tmdb:400"]?.request_id == 4)
        let (none, _) = backend([:])
        #expect(try await none.requestMap() == [:])
    }
}

struct ImportCleanupToolsTests {
    @Test func exclusionsFromEveryArrNewestFirst() async throws {
        let (direct, transport) = backend(["radarr": radarr, "sonarr": sonarr, "readarr": readarr, "lidarr": lidarr])
        transport.on("GET /api/v3/exclusions", json: #"[{"id": 3, "movieTitle": "Film", "movieYear": 0, "tmdbId": 9}]"#)
        transport.on("GET /api/v3/importlistexclusion", json: #"{"records": [{"id": 5, "title": "Show", "tvdbId": 7}]}"#)
        transport.on("GET /api/v1/importlistexclusion", byPort([8686: """
        [{"id": 4, "artistName": "Band", "foreignId": "mbid"}]
        """]))
        let rows = try await direct.exclusions()
        #expect(rows == [
            Exclusion(app: "sonarr", id: 5, remote_id: "7", title: "Show"),
            Exclusion(app: "lidarr", id: 4, remote_id: "mbid", title: "Band"),
            Exclusion(app: "radarr", id: 3, remote_id: "9", title: "Film", year: nil),
        ])
    }

    @Test func anExclusionIsRemovedFromItsOwnArr() async throws {
        let (direct, transport) = backend(["radarr": radarr, "lidarr": lidarr])
        transport.on("DELETE /api/v3/exclusions/3", json: "")
        transport.on("DELETE /api/v1/importlistexclusion/4", json: "")
        try await direct.removeExclusion(app: "radarr", id: 3)
        try await direct.removeExclusion(app: "lidarr", id: 4)
        #expect(transport.requests.compactMap { $0.url?.path() } == ["/api/v3/exclusions/3", "/api/v1/importlistexclusion/4"])
        await #expect(throws: APIError.refused("unknown app 'plex'")) { try await direct.removeExclusion(app: "plex", id: 1) }
    }

    @Test func aReleaseNameAsRadarrReadsIt() async throws {
        let (direct, transport) = backend(["radarr": radarr])
        transport.on("GET /api/v3/parse", json: """
        {"parsedMovieInfo": {"movieTitles": ["Dune"], "year": 2021, "releaseGroup": "FLUX", "edition": "",
                             "quality": {"quality": {"name": "WEBDL-2160p", "source": "webdl", "resolution": 2160}},
                             "languages": [{"name": "English"}, {"name": "Unknown"}]},
         "movie": {"id": 7, "title": "Dune"}, "customFormats": [{"name": "DV"}, {"name": ""}], "customFormatScore": 150}
        """)
        let parsed = try await direct.parse(app: .radarr, title: "  Dune.2021.2160p.WEB-DL-FLUX \n")
        #expect(query(sent(transport, "GET", "/parse")[0]) == ["title": "Dune.2021.2160p.WEB-DL-FLUX"])
        #expect(parsed == ParseResult(
            app: "radarr", custom_format_score: 150, custom_formats: ["DV"], edition: nil, episodes: [], full_season: false,
            languages: ["English"], match_episodes: [], match_id: 7, match_title: "Dune", parsed_title: "Dune",
            quality: "WEBDL-2160p", release_group: "FLUX", resolution: 2160, season: nil, source: "webdl",
            title: "Dune.2021.2160p.WEB-DL-FLUX", year: 2021
        ))
    }

    @Test func aReleaseNameAsSonarrReadsIt() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/parse", json: """
        {"parsedEpisodeInfo": {"seriesTitle": "Show", "seasonNumber": 6, "episodeNumbers": [3, 4], "fullSeason": false,
                               "quality": {"quality": {"name": "HDTV-720p", "resolution": 720}}},
         "languages": [{"name": "Danish"}], "series": {"id": 2, "title": "Show"},
         "episodes": [{"seasonNumber": 6, "episodeNumber": 3, "title": "Ep"}, {"seasonNumber": 6, "episodeNumber": 4}]}
        """)
        let parsed = try await direct.parse(app: .sonarr, title: "Show.S06E03E04")
        #expect(parsed.parsed_title == "Show")
        #expect(parsed.season == 6)
        #expect(parsed.episodes == [3, 4])
        #expect(parsed.languages == ["Danish"])
        #expect(parsed.match_episodes == ["S06E03 Ep", "S06E04"])
        #expect(parsed.year == nil)
        #expect(parsed.custom_format_score == 0)
        #expect(parsed.episodeCode == "S06E03E04")
    }

    @Test func onlyRadarrAndSonarrParseAndOnlyANameIsParsed() async throws {
        let (direct, transport) = backend(["radarr": radarr, "readarr": readarr])
        await #expect(throws: APIError.refused("title is empty")) { try await direct.parse(app: .radarr, title: "  ") }
        await #expect(throws: APIError.refused("unknown app 'readarr'")) { try await direct.parse(app: .readarr, title: "x") }
        #expect(transport.requests.isEmpty)
    }

    @Test func everyShowWithItsSeasonsInOrder() async throws {
        let (direct, transport) = backend(["sonarr": sonarr])
        transport.on("GET /api/v3/series", json: """
        [{"id": 2, "sortTitle": "zed", "title": "Zed", "seasons": []},
         {"id": 1, "sortTitle": "alpha", "title": "Alpha", "monitored": true, "status": "continuing",
          "images": [{"coverType": "poster", "remoteUrl": "https://image.tmdb.org/t/p/original/a.jpg"}],
          "seasons": [{"seasonNumber": 2, "monitored": true, "statistics": {"episodeFileCount": 3, "totalEpisodeCount": 10}},
                      {"seasonNumber": 1}]}]
        """)
        let rows = try await direct.seasonGrid()
        #expect(rows.map(\.id) == [1, 2])
        let alpha = rows[0]
        #expect(alpha.poster == "https://image.tmdb.org/t/p/w500/a.jpg")
        #expect(alpha.status == "continuing")
        #expect(alpha.seasons == [
            .init(have: 0, monitored: false, number: 1, total: 0), .init(have: 3, monitored: true, number: 2, total: 10),
        ])
        #expect(rows[1].monitored == false)
    }
}
