import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct LibraryRowTests {
    @Test func movieStatusIsDerived() {
        #expect(LibraryRow(LibraryMovie(has_file: true, id: 1, monitored: true)).status == "downloaded")
        #expect(LibraryRow(LibraryMovie(has_file: false, id: 1, monitored: true)).status == "wanted")
        #expect(LibraryRow(LibraryMovie(has_file: false, id: 1, monitored: false)).status == "unmonitored")
        #expect(LibraryRow(LibraryMovie(id: 7)).ref == .movie(7))
        #expect(LibraryRow(LibrarySeries(id: 9, status: "continuing")).status == "continuing")
        #expect(LibraryRow(LibrarySeries(id: 9)).ref == .series(9))
    }

    @Test func filterAndSort() {
        let rows = [
            LibraryRow(LibraryMovie(id: 1, size_on_disk: 30, tags: [1], title: "Beta", year: 2020)),
            LibraryRow(LibraryMovie(id: 2, size_on_disk: 10, tags: [], title: "alpha", year: 2024)),
            LibraryRow(LibraryMovie(id: 3, size_on_disk: 20, tags: [1, 2], title: "Gamma", year: 2022)),
        ]
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .title, descending: false).map(\.id) == [2, 1, 3])
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .title, descending: true).map(\.id) == [3, 1, 2])
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .size, descending: true).map(\.id) == [1, 3, 2])
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .year, descending: false).map(\.id) == [1, 3, 2])
        #expect(LibrarySorting.apply(rows, query: " AM", tag: nil, sort: .title, descending: false).map(\.id) == [3])
        #expect(LibrarySorting.apply(rows, query: "", tag: 1, sort: .title, descending: false).map(\.id) == [1, 3])
        #expect(LibrarySort.keys(for: .radarr).contains(.episodes) == false)
        #expect(LibrarySort.keys(for: .sonarr).contains(.episodes))
    }

    @Test func serviceFieldsAndFlakiness() {
        #expect(ServiceField.fields(for: "qbittorrent") == [.url, .username, .password])
        #expect(ServiceField.fields(for: "transmission") == [.url])
        #expect(ServiceField.fields(for: "radarr") == [.url, .apiKey])
        #expect(ServiceStatus(ok: true, retries: 2, service: .radarr).isFlaky)
        #expect(!ServiceStatus(ok: false, retries: 2, service: .radarr).isFlaky)
        #expect(!ServiceStatus(ok: true, retries: 0, service: .radarr).isFlaky)
    }
}

actor FakeManageAPI: ManageAPI {
    var settings: [String: ServiceSettings] = [
        "radarr": .init(api_key: "k", configured: true, password: "", url: "http://r", username: ""),
        "plex": .init(api_key: "", configured: false, password: "", url: "", username: ""),
    ]
    var indexerList = [Indexer(enable: true, id: 1, name: "Zeta"), Indexer(enable: false, id: 2, name: "alpha")]
    var testFails = false
    var saveConfigured = true
    private(set) var calls: [String] = []
    func set(testFails: Bool) { self.testFails = testFails }
    func set(saveConfigured: Bool) { self.saveConfigured = saveConfigured }
    func count(_ c: String) -> Int { calls.filter { $0 == c }.count }
    fileprivate func log(_ c: String) { calls.append(c) }

    func libraryMovies() async throws -> [LibraryMovie] { log("movies"); return [.init(id: 1, title: "Film")] }
    func librarySeries() async throws -> [LibrarySeries] { log("series"); return [] }
    func libraryBooks() async throws -> [LibraryBook] { log("books"); return [.init(author: "Gibson", has_file: true, id: 133, title: "Count Zero", year: 1986)] }
    func tags(_ app: ArrApp) async throws -> [LibraryTag] { log("tags"); return [.init(id: 1, label: "kids")] }
    func indexers() async throws -> [Indexer] { log("indexers"); return indexerList }
    func toggleIndexer(_ id: Int, enable: Bool) async throws {
        log("toggle-\(id)-\(enable)")
        indexerList = indexerList.map { var i = $0; if i.id == id { i.enable = enable }; return i }
    }
    func testIndexer(_ id: Int) async throws { log("test-\(id)"); if testFails { throw APIError.unexpectedStatus(502) } }
    func status() async throws -> [ServiceStatus] { log("status"); return [.init(ok: true, service: .radarr, version: "6")] }
    func tasks() async throws -> Block<[ScheduledTask]> {
        log("tasks")
        return .healthy([
            .init(app: "radarr", label: "RSS Sync", name: "RssSync", notable: true, overdue: false),
            .init(app: "sonarr", label: "Housekeeping", name: "Housekeeping", notable: false, overdue: true),
            .init(app: "sonarr", label: "Backup", name: "Backup", notable: false, overdue: false),
        ])
    }
    func arrBackups() async throws -> Block<[ArrBackup]> { log("backups"); return .healthy([]) }
    func logs(_ app: String, level: String?) async throws -> [LogEntry] {
        log("logs-\(app)-\(level ?? "all")")
        return [.init(app: app, level: "info", message: "hi")]
    }
    func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles { log("profiles-\(app.rawValue)"); return .init() }
    func serviceSettings() async throws -> [String: ServiceSettings] { log("settings"); return settings }
    func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool {
        log("save-\(name)-\(url)")
        return saveConfigured
    }
    func testService(_ name: String) async throws -> String {
        log("test-service-\(name)")
        if testFails { throw APIError.transport("refused") }
        return "6.4.4"
    }
}

/// LibraryListModel also needs LibraryAPI; the fake gets a minimal one.
extension FakeManageAPI: LibraryAPI {
    func movieDetail(_ id: Int) async throws -> MovieDetail { .init(id: id) }
    func movieCredits(_ id: Int) async throws -> Credits { .init() }
    func seriesDetail(_ id: Int) async throws -> SeriesDetail { .init(id: id, seasons: []) }
    func bookDetail(_ id: Int) async throws -> BookDetail { .init(id: id) }
    func episodes(series: Int, season: Int) async throws -> [Episode] { [] }
    func options(_ app: ArrApp) async throws -> Options { .init(quality_profiles: [], root_folders: []) }
    func watched() async throws -> Block<WatchedMap> { log("watched"); return .healthy(.init()) }
    func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws {}
    func delete(_ ref: MediaRef, deleteFiles: Bool) async throws {}
    func triggerSearch(_ ref: MediaRef) async throws {}
    func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {}
    func searchSeason(series: Int, season: Int) async throws {}
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {}
    func searchEpisodes(_ ids: [Int]) async throws {}
}

@MainActor
@Suite struct ManageModelTests {
    @Test func libraryLoadsRowsTagsAndPlexOnlyWhenConfigured() async {
        let api = FakeManageAPI()
        let model = LibraryListModel(app: .radarr, api: api, hasPlex: false, onSessionLost: {})
        await model.load()
        #expect(model.shown.map(\.title) == ["Film"])
        #expect(model.tags.map(\.label) == ["kids"])
        #expect(await api.count("watched") == 0)
        model.query = "zzz"
        #expect(model.shown.isEmpty)
    }

    @Test func indexersToggleRefetchAndTestsAreVerdicts() async {
        let api = FakeManageAPI()
        let model = IndexersModel(api: api, onSessionLost: {})
        await model.load()
        #expect(model.sorted.map(\.name) == ["alpha", "Zeta"])
        await model.setEnabled(model.sorted[0], true)
        #expect(await api.count("toggle-2-true") == 1)
        #expect(model.sorted[0].enable == true, "refetched after the toggle")
        await model.test(model.sorted[0])
        #expect(model.tested[2] == true)
        await api.set(testFails: true)
        await model.test(model.sorted[1])
        #expect(model.tested[1] == false)
        #expect(model.actionError == nil, "a failed test is a result, not an error")
    }

    @Test func systemShowsNotableOrOverdueUnlessAsked() async throws {
        let api = FakeManageAPI()
        let model = SystemModel(configured: ["radarr", "sonarr", "prowlarr"], api: api, onSessionLost: {})
        await model.load()
        #expect(model.shownTasks.map(\.name) == ["RssSync", "Housekeeping"])
        #expect(model.overdueCount == 1)
        model.showAllTasks = true
        #expect(model.shownTasks.count == 3)
        #expect(model.profiles.count == 2)
        #expect(model.logApps == ["radarr", "sonarr", "prowlarr"])
        #expect(model.logs.value?.count == 1)

        model.logApp = "prowlarr"
        model.logLevel = "error"
        try await Task.sleep(for: .milliseconds(100))
        // Two edits, one or two fetches — the generation counter drops the
        // stale answer either way; what matters is the last request.
        #expect(await api.calls.last == "logs-prowlarr-error")
    }

    @Test func servicesFormsTrackDirtinessAndResults() async {
        let api = FakeManageAPI()
        let model = ServicesModel(api: api, onSessionLost: {})
        await model.load()
        let forms = model.forms
        #expect(model.loaded)
        #expect(forms.map(\.name) == ["radarr", "plex"], "backend order, configured arrs first")
        let radarr = forms[0]
        #expect(!radarr.dirty)
        #expect(radarr.configured)
        radarr.url = "http://new"
        #expect(radarr.dirty)
        await model.save(radarr)
        #expect(await api.count("save-radarr-http://new") == 1)
        #expect(!radarr.dirty, "the saved values follow the save")
        #expect(radarr.result == "ok: saved")

        await model.test(radarr)
        #expect(radarr.result == "ok: v6.4.4")
        await api.set(testFails: true)
        await model.test(radarr)
        #expect(radarr.result == "error: refused")
        #expect(!radarr.resultOK)

        await api.set(saveConfigured: false)
        let plex = forms[1]
        plex.url = "http://plex"
        await model.save(plex)
        #expect(plex.result == "saved (disabled)")
        #expect(!plex.configured)
    }
}

/// The library list also needs ExtrasAPI for its bulk actions.
extension FakeManageAPI: ExtrasAPI {
    func releases(_ target: ReleaseTarget) async throws -> [ArrRelease] { [] }
    func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws {}
    func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview] { [] }
    func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws {}
    func addTorrent(_ client: TorrentClient, url: String, category: String, paused: Bool) async throws {}
    func qbitCategories() async throws -> [String] { [] }
    func qbitTags() async throws -> [String] { [] }
    func setLimits(_ client: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws {}
    func setPriority(_ client: TorrentClient, ids: [String], position: QueuePosition) async throws {}
    func forceStart(ids: [String]) async throws {}
    func setTags(ids: [String], tags: [String], remove: Bool) async throws {}
    func setCategory(id: String, category: String) async throws {}
    func bulkEdit(_ app: ArrApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?) async throws {
        log("bulk-\(ids.map(String.init).joined(separator: ","))-\(monitored.map(String.init) ?? "_")-\(qualityProfile.map(String.init) ?? "_")-\(tags?.first.map(String.init) ?? "_")-\(tagChange?.rawValue ?? "_")")
    }
    func addTorrentFile(_ client: TorrentClient, filename: String, data: Data, category: String, paused: Bool) async throws {}
    func bulkDelete(_ app: ArrApp, ids: [Int], deleteFiles: Bool) async throws { log("bulkdelete-\(ids.count)-\(deleteFiles)") }
    func bulkSearch(_ app: ArrApp, ids: [Int]) async throws { log("bulksearch-\(ids.count)") }
}

@MainActor
@Suite struct LibraryBulkTests {
    @Test func selectionDrivesBulkActionsAndRefetches() async {
        let api = FakeManageAPI()
        let model = LibraryListModel(app: .radarr, api: api, hasPlex: false, onSessionLost: {})
        await model.load()
        let row = model.shown[0]
        model.selecting = true
        model.toggleSelection(row)
        #expect(model.selected == [1])
        await model.bulk(.monitor(false))
        #expect(await api.count("bulk-1-false-_-_-_") == 1)
        #expect(!model.selecting, "a bulk action leaves select mode")
        #expect(model.selected.isEmpty)
        #expect(await api.count("movies") == 2, "and refetches the list")

        model.selecting = true
        model.toggleSelection(row)
        await model.bulk(.tag(7, add: true))
        #expect(await api.count("bulk-1-_-_-7-add") == 1)
        model.selecting = true
        model.toggleSelection(row)
        await model.bulk(.delete(deleteFiles: true))
        #expect(await api.count("bulkdelete-1-true") == 1)
        await model.bulk(.search)
        #expect(await api.count("bulksearch-1") == 0, "nothing selected, nothing sent")
    }
}
