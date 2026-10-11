import ArrdeckAPI
import ArrdeckGlance
import Foundation
import Testing
@testable import ArrdeckData

/// The names this build knows against the ones the pinned server can send.
/// The derived spec has no enums for them any more (Scripts/derive-spec.jq),
/// so the server's own spec in the submodule is the one read here.
struct OpenNamesContractTests {
    func spec(_ path: String) throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let data = try Data(contentsOf: dir.appending(path: path))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every enum value of a schema property called `name`, across the spec.
    func enumValues(_ name: String, in spec: [String: Any]) -> Set<String> {
        let schemas = (spec["components"] as? [String: Any])?["schemas"] as? [String: Any] ?? [:]
        var values = Set<String>()
        for case let schema as [String: Any] in schemas.values {
            guard let property = (schema["properties"] as? [String: Any])?[name] as? [String: Any] else { continue }
            values.formUnion(property["enum"] as? [String] ?? [])
        }
        return values
    }

    @Test func everyArrAndServiceTheServerNamesIsKnown() throws {
        let server = try spec("arrdeck/openapi.json")
        let apps = enumValues("app", in: server)
        let services = enumValues("service", in: server)
        #expect(apps.contains("lidarr") && services.contains("lidarr"), "the pin is the server's Lidarr support")
        let arrs = Set(ArrApp.allCases.map(\.rawValue))
        #expect(apps.subtracting(arrs).isEmpty, "arrs the server sends that ArrApp lacks: \(apps.subtracting(arrs).sorted())")
        #expect(services.subtracting(Services.known).isEmpty,
                "services the server sends that Services.known lacks: \(services.subtracting(Services.known).sorted())")
        #expect(Set(ArrApp.allCases.map(\.rawValue)).isSubset(of: Services.known))
    }

    @Test func theDerivedSpecLeavesThoseNamesOpen() throws {
        let derived = try spec("Sources/ArrdeckAPI/openapi.json")
        #expect(enumValues("app", in: derived).isEmpty, "run Scripts/derive-spec.sh")
        #expect(enumValues("service", in: derived).isEmpty, "run Scripts/derive-spec.sh")
    }
}

@Suite struct LidarrNamesTests {
    @Test func lidarrIsAnArrButNotALibraryTab() {
        #expect(ArrApp(rawValue: "lidarr") == .lidarr)
        #expect(Services.label("lidarr") == "Lidarr")
        #expect(ArrApp.lidarr.symbol == "music.note")
        #expect(ArrApp.radarr.symbol == AppTab.movies.symbol && ArrApp.readarr.symbol == AppTab.books.symbol)
        #expect(LibraryApp(.lidarr) == nil)
        #expect(LibraryApp.allCases.map(\.arr) == [.radarr, .sonarr, .readarr])
        #expect(!DisplaySync.keys.contains { $0.hasSuffix(".music") || $0.hasSuffix(".lidarr") },
                "no music layout is synced until there is a music tab")
    }

    @Test func lidarrAloneGivesActivityAndCalendar() {
        #expect(AppTab.available(configured: ["lidarr"]) == [.activity, .calendar, .settings])
    }

    @Test func connectionsTakeAnAddressAndAKey() {
        #expect(ServiceField.fields(for: "lidarr") == [.url, .apiKey])
        #expect(serviceOrder.firstIndex(of: "lidarr")! < serviceOrder.firstIndex(of: "prowlarr")!, "with the arrs")
    }
}

/// The answers as the server writes them once Lidarr is configured.
@Suite struct LidarrDecodingTests {
    func api(_ routes: [String: StubTransport.Route]) -> LiveAPI {
        LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: StubTransport(routes: routes)))
    }

    @Test func lidarrSlicesArriveBesideTheOthers() async throws {
        let api = api([
            "/api/v1/queue": .init(body: """
            {"radarr": {"ok": true, "data": []}, "sonarr": {"ok": true, "data": []},
             "lidarr": {"ok": true, "data": [
               {"app": "lidarr", "id": 12, "title": "Boards of Canada — Geogaddi", "status": "completed",
                "tracked_state": "importBlocked", "size": 300, "size_left": 0, "needs_attention": true}]}}
            """),
            "/api/v1/calendar": .init(body: """
            {"radarr": {"ok": true, "data": []}, "sonarr": {"ok": true, "data": []},
             "lidarr": {"ok": true, "data": [
               {"app": "lidarr", "title": "Inferno", "date": "2026-10-16T00:00:00Z", "has_file": false,
                "extra": "Boards of Canada", "item_id": 5, "poster": "/api/v1/poster?u=x"}]}}
            """),
            "/api/v1/history": .init(body: """
            {"radarr": {"ok": true, "data": []}, "sonarr": {"ok": true, "data": []},
             "lidarr": {"ok": false, "data": null, "error": "lidarr: 502"}}
            """),
            "/api/v1/status": .init(body: """
            [{"service": "lidarr", "ok": true, "version": "2.13.3", "update_available": "2.14.0"}]
            """),
            "/api/v1/services": .init(body: """
            [{"service": "lidarr", "configured": true, "web_url": "http://lidarr.local:8686"}]
            """),
        ])
        let queue = try await api.queue()
        let item = try #require(queue[.lidarr]?.value?.first)
        #expect(item.arr == .lidarr)
        #expect(item.importable)
        let calendar = try await api.calendar()
        #expect(calendar[.lidarr]?.value?.first?.extra == "Boards of Canada")
        #expect(try await api.history()[.lidarr] == .offline("lidarr: 502"))
        let status = try await api.status()
        #expect(status.first?.service == "lidarr" && status.first?.update_available == "2.14.0")
        #expect(try await api.services().map(\.service) == ["lidarr"])
    }

    @Test func artistsAndTheirAlbums() async throws {
        let api = api([
            "/api/v1/library/artists": .init(body: """
            [{"id": 1, "name": "Boards of Canada", "sort_name": "boards of canada", "monitored": true,
              "album_count": 5, "track_file_count": 40, "poster": null},
             {"id": 2, "name": "Autechre", "album_count": 15}]
            """),
            "/api/v1/library/artists/1/albums": .init(body: """
            [{"id": 5, "title": "Inferno", "artist_id": 1, "artist": "Boards of Canada", "year": 2026,
              "release_date": "2026-10-16T00:00:00Z", "album_type": "Album", "monitored": true,
              "track_count": 19, "track_file_count": 0, "poster": null},
             {"id": 1, "title": "Geogaddi", "artist_id": 1, "year": 2002, "album_type": "Album", "track_count": 24}]
            """),
        ])
        let artists = try await api.libraryArtists()
        #expect(artists.map(\.name) == ["Boards of Canada", "Autechre"])
        #expect(ImportTargetSearch.artists(artists, query: "boards").map(\.id) == [1])
        let albums = try await api.artistAlbums(1)
        #expect(albums.map(\.title) == ["Inferno", "Geogaddi"], "the server's order, newest first")
        #expect(ImportTargetSearch.albums(albums, query: "geo").map(\.id) == [1])
        #expect(ImportTargetSearch.albumLabel(artist: "Boards of Canada", album: albums[1]) == "Boards of Canada — Geogaddi")
    }

    @Test func anAlbumIsSearchedThroughTheLibraryRoute() async throws {
        let api = api(["/api/v1/library/lidarr/5/search": .init(status: 204, body: "")])
        try await api.searchAlbum(5)
    }
}

@MainActor
@Suite struct LidarrCalendarTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    actor Fake: CalendarAPI {
        func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>] {
            [
                .radarr: .healthy([]),
                .sonarr: .healthy([.init(app: "sonarr", date: "2026-10-16T01:00:00Z", extra: "S01E01 Pilot", item_id: 9, title: "A Show")]),
                .lidarr: .healthy([
                    .init(app: "lidarr", date: "2026-10-16T00:00:00Z", extra: "Boards of Canada", item_id: 5, title: "Inferno"),
                    .init(app: "lidarr", date: "2026-10-16T00:00:00Z", extra: "Boards of Canada", item_id: 6, title: "Inferno (Remixes)"),
                ]),
            ]
        }
    }

    @Test func albumsLandOnTheirReleaseDayAndOpenNothing() async throws {
        let model = CalendarModel(api: Fake(), calendar: utc, now: { Date(timeIntervalSince1970: 1_791_720_000) }, onSessionLost: {})
        defer { model.hiddenApps = [] }
        await model.load()
        #expect(model.apps == [.radarr, .sonarr, .lidarr])
        let day = try #require(model.days.first { $0.day == "2026-10-16" })
        let albums = day.entries.filter { $0.item.arr == .lidarr }
        #expect(albums.count == 2, "two albums by one artist are two rows, not a fold")
        #expect(albums.allSatisfy { $0.item.ref == nil && $0.code == nil })
        model.hiddenApps = [.lidarr]
        #expect(model.items.map(\.title) == ["A Show"])
    }

    @Test func todaysAlbumsAreAlbumsInTheWidget() throws {
        let item = CalendarItem(app: "lidarr", date: "2026-10-11T00:00:00Z", extra: "Boards of Canada", item_id: 5, title: "Inferno")
        let today = try #require(GlanceSnapshot.today([.lidarr: .healthy([item])], now: Date(timeIntervalSince1970: 1_791_720_000), calendar: utc))
        #expect(today.entries.map(\.kind) == [.album])
        #expect(today.entries.first?.time == nil, "a release day has no time")
    }
}

@MainActor
@Suite struct LidarrQueueTests {
    let album = QueueItem(app: "lidarr", id: 12, size: 300, size_left: 0, status: "completed",
                          title: "Boards of Canada — Geogaddi", tracked_state: "importPending")

    @Test func queueActionsGoToLidarr() async {
        let api = FakeDownloadsAPI(groups: [:])
        let model = DownloadsModel(api: api, clients: [], hasArr: true, arrs: [.lidarr], onSessionLost: {})
        await model.forceImport(album)
        await model.blocklistRetry(album)
        await model.removeFromQueue(album)
        #expect(await api.count("force") == 1)
        #expect(await api.count("retry") == 1)
        #expect(await api.count("remove-lidarr-12") == 1)
        #expect(album.importable, "Fix opens the import sheet on it")
    }
}

/// Lidarr's files are tracks: one album pick places a whole folder, Lidarr
/// matches the tracks, and no language is ever sent.
@Suite struct LidarrImportTests {
    func track(_ n: Int, placed: Bool = false) -> ImportCandidate {
        ImportCandidate(importable: placed, language_ids: [], languages: [], name: "side a \(n)",
                        path: "/downloads/rip/side a \(n).mp3", quality: "MP3-320", quality_id: 9,
                        rejections: placed ? [] : ["Couldn't find similar album"], size: 10,
                        title: placed ? "Music Has the Right to Children" : "")
    }

    @Test func anAlbumGoesToEveryFileNobodyHasPlaced() {
        let files = [track(1), track(2), track(3, placed: true)]
        var picks = ImportPicks()
        picks.assign(.album(1, label: "Boards of Canada — Geogaddi"), to: files[0], among: files)
        #expect(picks.targets[files[1].path]?.albumID == 1)
        #expect(picks.targets[files[2].path] == nil, "the file Lidarr placed is left alone")
        let request = picks.request(for: .queue(app: .lidarr, itemID: 4), candidates: files)
        #expect(request == .assign(.lidarr, .init(
            files: [.init(album_id: 1, path: files[0].path), .init(album_id: 1, path: files[1].path)],
            item_id: 4, mode: .auto
        )))
    }

    @Test func aFileAlreadyPointedElsewhereKeepsItsAlbum() {
        let files = [track(1), track(2), track(3)]
        var picks = ImportPicks()
        picks.assign(.album(7, label: "Autechre — Amber"), to: files[2])
        picks.assign(.album(1, label: "Boards of Canada — Geogaddi"), to: files[0], among: files)
        #expect(picks.targets.mapValues(\.albumID) == [files[0].path: 1, files[1].path: 1, files[2].path: 7])
    }

    @Test func otherTargetsStayOnTheirOneFile() {
        let files = [track(1), track(2)]
        var picks = ImportPicks()
        picks.assign(.movie(4, label: "Dune"), to: files[0], among: files)
        #expect(picks.targets[files[1].path] == nil)
    }

    @Test func aFinishedTorrentGoesToLidarrsTorrentEndpointWithQualityOnly() {
        let files = [track(1)]
        var picks = ImportPicks()
        picks.assign(.album(1, label: "x"), to: files[0], among: files)
        picks.setQuality(4, for: files[0])
        picks.mode = .copy
        let request = picks.request(for: .torrent(app: .lidarr, client: .qbittorrent, torrentID: "ab"), candidates: files)
        #expect(request == .torrent(.lidarr, .init(
            client: .qbittorrent, files: [.init(album_id: 1, path: files[0].path, quality_id: 4)],
            mode: .copy, torrent_id: "ab"
        )))
    }

    @Test func theWireCarriesAlbumIDAndNoLanguages() async throws {
        let command = #"{"app": "lidarr", "id": 5, "status": "queued", "done": false}"#
        let transport = ImportRecordingTransport(routes: [
            "/api/v1/manual-import/lidarr/assign": .init(body: command),
            "/api/v1/manual-import/lidarr/options": .init(body: #"{"qualities": [{"id": 9, "name": "MP3-320"}], "languages": []}"#),
        ])
        let api = LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: transport))
        let started = try await api.startImport(.assign(.lidarr, .init(
            files: [.init(album_id: 1, path: "/a.mp3")], item_id: 4, mode: .auto
        )))
        #expect(started.app == "lidarr")
        let body = try JSONSerialization.jsonObject(with: Data(transport.requests[0].body.utf8)) as! NSDictionary
        #expect(body == ["item_id": 4, "mode": "auto", "files": [["path": "/a.mp3", "album_id": 1]]] as NSDictionary)
        let options = try await api.importOptions(.lidarr)
        #expect(options.languages?.isEmpty == true && options.qualities?.count == 1)
    }

    @MainActor @Test func theSheetSaysTheAlbumGoesToAllOnlyForSeveralUnplacedTracks() async {
        let several = ImportModel(source: .queue(app: .lidarr, itemID: 4),
                                  api: FakeImportAPI(candidates: [track(1), track(2), track(3, placed: true)], states: []),
                                  onSessionLost: {})
        await several.load()
        #expect(several.albumForAll)
        several.assign(.album(1, label: "x"), to: several.list[1])
        #expect(several.chosenCount == 2)

        let one = ImportModel(source: .queue(app: .lidarr, itemID: 4),
                              api: FakeImportAPI(candidates: [track(1), track(2, placed: true)], states: []),
                              onSessionLost: {})
        await one.load()
        #expect(!one.albumForAll)

        let films = ImportModel(source: .queue(app: .radarr, itemID: 4),
                                api: FakeImportAPI(candidates: [track(1), track(2)], states: []), onSessionLost: {})
        await films.load()
        #expect(!films.albumForAll)
    }
}
