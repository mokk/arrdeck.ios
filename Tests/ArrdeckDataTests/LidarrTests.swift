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
    @Test func lidarrIsAnArrWithALibraryTab() {
        #expect(ArrApp(rawValue: "lidarr") == .lidarr)
        #expect(Services.label("lidarr") == "Lidarr")
        #expect(ArrApp.lidarr.symbol == "music.note")
        #expect(ArrApp.radarr.symbol == AppTab.movies.symbol && ArrApp.readarr.symbol == AppTab.books.symbol)
        #expect(ArrApp.lidarr.symbol == AppTab.music.symbol)
        #expect(LibraryApp(.lidarr) == .lidarr)
        #expect(LibraryApp.allCases.map(\.arr) == [.radarr, .sonarr, .readarr, .lidarr])
        #expect(LibraryApp.lidarr.libraryKind == "artists", "the Music tab's bulk actions address artists")
    }

    @Test func lidarrAloneGivesMusicActivityAndCalendar() {
        #expect(AppTab.available(configured: ["lidarr"]) == [.music, .activity, .calendar, .settings])
        #expect(AppTab.available(configured: ["readarr", "radarr", "sonarr", "lidarr"]).prefix(4) == [.books, .movies, .shows, .music])
    }

    @Test func connectionsTakeAnAddressAndAKey() {
        #expect(ServiceField.fields(for: "lidarr") == [.url, .apiKey])
        #expect(serviceOrder.firstIndex(of: "lidarr")! < serviceOrder.firstIndex(of: "prowlarr")!, "with the arrs")
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

    @Test func albumsLandOnTheirReleaseDayAndOpenTheAlbum() async throws {
        let model = CalendarModel(api: Fake(), calendar: utc, now: { Date(timeIntervalSince1970: 1_791_720_000) })
        defer { model.hiddenApps = [] }
        await model.load()
        #expect(model.apps == [.radarr, .sonarr, .lidarr])
        let day = try #require(model.days.first { $0.day == "2026-10-16" })
        let albums = day.entries.filter { $0.item.arr == .lidarr }
        #expect(albums.count == 2, "two albums by one artist are two rows, not a fold")
        #expect(albums.allSatisfy { $0.item.ref == $0.item.item_id.map(MediaRef.album) && $0.code == nil })
        #expect(albums.allSatisfy { $0.item.ref != nil })
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
        let model = DownloadsModel(api: api, clients: [], hasArr: true, arrs: [.lidarr])
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

    @MainActor @Test func theSheetSaysTheAlbumGoesToAllOnlyForSeveralUnplacedTracks() async {
        let several = ImportModel(source: .queue(app: .lidarr, itemID: 4),
                                  api: FakeImportAPI(candidates: [track(1), track(2), track(3, placed: true)], states: []))
        await several.load()
        #expect(several.albumForAll)
        several.assign(.album(1, label: "x"), to: several.list[1])
        #expect(several.chosenCount == 2)

        let one = ImportModel(source: .queue(app: .lidarr, itemID: 4),
                              api: FakeImportAPI(candidates: [track(1), track(2, placed: true)], states: []))
        await one.load()
        #expect(!one.albumForAll)

        let films = ImportModel(source: .queue(app: .radarr, itemID: 4),
                                api: FakeImportAPI(candidates: [track(1), track(2)], states: []))
        await films.load()
        #expect(!films.albumForAll)
    }
}
