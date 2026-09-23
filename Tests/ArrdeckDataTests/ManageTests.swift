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

    @Test func letterIndexAndUnmonitored() {
        let dune = LibraryRow(LibraryMovie(id: 1, monitored: false, title: "dune"))
        let odyssey = LibraryRow(LibraryMovie(id: 2, title: "2001: A Space Odyssey"))
        #expect(LibrarySorting.letter(dune, sort: .title) == "D")
        #expect(LibrarySorting.letter(odyssey, sort: .title) == "#")
        #expect(LibrarySorting.letter(LibraryRow(LibraryBook(author: "Ørsted", id: 3)), sort: .author) == "Ø")
        #expect(LibrarySorting.isAlphabetical(.title) && !LibrarySorting.isAlphabetical(.added))
        // a film is unmonitored when neither wanted nor on disk; a show by its flag
        #expect(dune.isUnmonitored)
        #expect(!LibraryRow(LibraryMovie(has_file: true, id: 4, monitored: false)).isUnmonitored)
        #expect(LibraryRow(LibrarySeries(id: 5, monitored: false, status: "ended")).isUnmonitored)
    }

    @Test func upNextPutsAiringShowsFirstSoonestFirst() {
        let later = LibraryRow(LibrarySeries(id: 1, next_episode: .init(air_date: Date(timeIntervalSince1970: 2_000), episode: 1, season: 1), title: "Later"))
        let sooner = LibraryRow(LibrarySeries(id: 2, next_episode: .init(air_date: Date(timeIntervalSince1970: 1_000), episode: 4, season: 3), title: "Sooner"))
        let idle = LibraryRow(LibrarySeries(id: 3, title: "Idle"))
        let split = LibrarySorting.upNext([later, idle, sooner])
        #expect(split.airing.map(\.id) == [2, 1])
        #expect(split.idle.map(\.id) == [3])
        #expect(LibraryLayout.options(for: .sonarr).contains(.upNext))
        #expect(!LibraryLayout.options(for: .radarr).contains(.shelf))
        #expect(LibraryLayout.shelf.ownsOrder && !LibraryLayout.list.ownsOrder)
    }

    @Test func detailFactsAreCarried() {
        let row = LibraryRow(LibraryMovie(id: 1, quality: "WEBDL-2160p", rating: 7.4, slug: "1078605"))
        #expect(row.quality == "WEBDL-2160p" && row.rating == 7.4 && row.slug == "1078605")
        #expect(LibraryRow(LibrarySeries(id: 2, network: "Apple TV")).network == "Apple TV")
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
    func movieSubtitles(_ id: Int) async throws -> TitleSubtitles { .init() }
    func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles] { [] }
    func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws {}
    func deleteEpisodeFile(_ fileID: Int) async throws {}
    func authorDetail(_ id: Int) async throws -> AuthorDetail { .init(id: id) }
    func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary { .init(id: id) }
    func bookEditions(edition: String) async throws -> [EditionChoice] { [] }
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

@Suite struct DisplayPrefsTests {
    @Test func tabsFollowTheSavedOrderAndNeverHideSettings() {
        let all: [AppTab] = [.books, .movies, .shows, .activity, .calendar, .settings]
        #expect(AppTab.arrange(all, order: [.shows, .movies], hidden: []) == [.shows, .movies, .books, .activity, .calendar, .settings])
        #expect(AppTab.arrange(all, order: [], hidden: [.calendar, .settings]) == [.books, .movies, .shows, .activity, .settings])
        #expect(AppTab.list("shows,bogus,books") == [.shows, .books])
    }

    @Test func spoilerRules() {
        #expect(!SpoilerGuard.hides(season: 1, episode: 2, mode: .off, watched: nil))
        #expect(SpoilerGuard.hides(season: 1, episode: 2, mode: .always, watched: ["1x2"]))
        #expect(!SpoilerGuard.hides(season: 1, episode: 2, mode: .unwatched, watched: ["1x2"]))
        #expect(SpoilerGuard.hides(season: 1, episode: 3, mode: .unwatched, watched: ["1x2"]))
        #expect(SpoilerGuard.hides(season: 1, episode: 2, mode: .unwatched, watched: nil), "no answer from Plex errs on the safe side")
    }

    @Test func confirmPolicy() {
        #expect(ConfirmPolicy.always.asks(destructive: false))
        #expect(!ConfirmPolicy.deletes.asks(destructive: false) && ConfirmPolicy.deletes.asks(destructive: true))
        #expect(!ConfirmPolicy.never.asks(destructive: true))
    }

    @Test func sizesAndDates() {
        let en = Locale(identifier: "en_US")
        #expect(Format.bytes(1_500_000_000, locale: en, style: .decimal) == "1.5 GB")
        #expect(Format.bytes(1_500_000_000, locale: en, style: .binary) == "1.4 GB")
        let now = Date(timeIntervalSince1970: 1_790_139_600) // 2026-09-23
        #expect(Format.when(Date(timeIntervalSince1970: 978_307_200), style: .absolute, now: now, locale: en).contains("2001"))
        #expect(!Format.when(now.addingTimeInterval(-86_400 * 3), style: .absolute, now: now, locale: en).contains("2026"))
    }
}

@Suite struct TitleSequenceTests {
    @Test func neighboursFollowTheList() {
        let refs: [MediaRef] = [.movie(1), .movie(2), .movie(3)]
        #expect(TitleSequence.neighbours(of: .movie(2), in: refs) == (.movie(1), .movie(3)))
        #expect(TitleSequence.neighbours(of: .movie(1), in: refs).previous == nil)
        #expect(TitleSequence.neighbours(of: .movie(9), in: refs) == (nil, nil))
    }
}

@Suite struct CleanupAndRequestsTests {
    @Test func forecastProjectsASteadyLoss() {
        let day = 86_400
        let losing = (0..<30).map { StatsSample(disk_free_bytes: 1_000_000_000_000 - $0 * 10_000_000_000, ts: 1_790_000_000 + $0 * day) }
        guard case let .full(days, perDay) = DiskForecast.compute(losing) else { Issue.record("expected a date"); return }
        #expect(Int(perDay / 1e9) == 10 && Int(days.rounded()) == 71)
        let flat = (0..<30).map { StatsSample(disk_free_bytes: 500_000_000_000, ts: 1_790_000_000 + $0 * day) }
        #expect(DiskForecast.compute(flat) == .steady)
        #expect(DiskForecast.compute(Array(losing.prefix(5))) == .unknown)
    }

    @Test func requestsAreFoundByKindAndId() {
        let pending = RequestState(request_id: 1, requested_by: "mokk", status: 1)
        let map = ["movie:tmdb:5": pending, "tv:tvdb:9": RequestState(request_id: 2, status: 2)]
        #expect(RequestLookup.find(map, movieTMDB: 5)?.request_id == 1)
        #expect(RequestLookup.find(map, showTVDB: 9)?.request_id == 2)
        #expect(RequestLookup.find(map, movieTMDB: 9) == nil, "a film and a show sharing a number stay apart")
    }

    @MainActor @Test func cleanupSelectionAndTotal() {
        let model = CleanupModel(api: FakeCleanupAPI())
        let a = CleanupItem(id: 1, kind: .movie, size: 4_000)
        let b = CleanupItem(id: 1, kind: .series, size: 6_000)
        model.toggle(a)
        model.toggle(b)
        #expect(CleanupModel.total(model.chosen) == 10_000, "the same id in films and shows is two titles")
        model.toggle(a)
        #expect(model.chosen.map(\.key) == ["series:1"])
    }
}

struct FakeCleanupAPI: CleanupAPI {
    func cleanup(watchedDays: Int) async throws -> CleanupLists { CleanupLists() }
    func deleteForCleanup(_ app: ArrApp, ids: [Int], exclude: Bool) async throws {}
}

@Suite struct ReadingTests {
    @Test func statusesAndTheCatalogueAddress() {
        #expect(ReadingStatus(rawValue: "to_read") == .toRead)
        #expect(Reading(status: .reading, updated_at: 1).readingStatus == .reading)
        let base = URL(string: "http://10.0.0.154:3500")!
        #expect(OpdsSettings(enabled: true, token: "abc").url(on: base)?.absoluteString == "http://10.0.0.154:3500/opds/abc")
        #expect(OpdsSettings(enabled: false).url(on: base) == nil)
    }
}

@Suite struct GlobalSearchTests {
    @Test func groupsAndRanksAcrossLibraries() {
        let rows = [
            LibraryRow(LibraryMovie(id: 1, title: "The Dune Sea")),
            LibraryRow(LibraryMovie(id: 2, title: "Dune")),
            LibraryRow(LibrarySeries(id: 3, title: "Dune: Prophecy")),
            LibraryRow(LibraryBook(author: "Frank Herbert", id: 4, title: "Dune Messiah")),
        ]
        let hits = GlobalSearch.hits(rows, authors: [(9, "Frank Herbert")], query: "dune")
        #expect(hits.map(\.id) == ["\(MediaRef.movie(2))", "\(MediaRef.movie(1))", "\(MediaRef.series(3))", "\(MediaRef.book(4))"])
        #expect(GlobalSearch.hits(rows, authors: [(9, "Frank Herbert")], query: "herb").map(\.group) == [.authors])
        #expect(GlobalSearch.hits(rows, authors: [], query: "d").isEmpty, "one letter is too little to search")
    }
}
