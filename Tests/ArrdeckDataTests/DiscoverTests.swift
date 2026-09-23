import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct SearchResultTests {
    @Test func libraryStateAndRef() {
        let none = SearchResult(kind: .movie, remote_id: 1, title: "x")
        #expect(none.libraryState == "not in library")
        #expect(none.ref == nil)
        let have = SearchResult(has_file: true, in_library: true, kind: .series, library_id: 63, remote_id: 1, title: "x")
        #expect(have.libraryState == "downloaded")
        #expect(have.ref == .series(63))
        #expect(SearchResult(in_library: true, kind: .movie, monitored: false, remote_id: 1, title: "x").libraryState == "in library, unmonitored")
        #expect(SearchResult(in_library: true, kind: .movie, monitored: true, remote_id: 1, title: "x").libraryState == "monitored")
    }

    @Test func linksFollowTheKind() {
        let series = SearchResult(kind: .series, remote_id: 376098, title: "x", tmdb_id: 95350)
        #expect(series.externalLinks.map(\.label) == ["TMDB", "TVDB"])
        #expect(series.externalLinks[0].url.absoluteString == "https://www.themoviedb.org/tv/95350")
        let movie = SearchResult(imdb_id: "tt1", kind: .movie, remote_id: 5, title: "x")
        #expect(movie.externalLinks.map(\.label) == ["IMDb"])
    }

    @Test func popularAgeAndTabs() {
        let now = Date(timeIntervalSince1970: 1_790_139_600)
        #expect(PopularRelease(published: "2026-09-23T02:00:00Z").hoursOld(now: now) == 3)
        #expect(PopularRelease(published: nil).hoursOld(now: now) == nil)
        #expect(AddTab.collections.service == "radarr")
        #expect(AddTab.releases.service == "prowlarr")
    }
}

actor FakeDiscoverAPI: DiscoverAPI, LibraryAPI {
    var failure: APIError?
    private(set) var calls: [String] = []
    func set(failure: APIError?) { self.failure = failure }
    func count(_ c: String) -> Int { calls.filter { $0 == c }.count }
    private func log(_ c: String) throws {
        calls.append(c)
        if let failure { throw failure }
    }

    func search(_ kind: MediaKind, query: String) async throws -> [SearchResult] {
        try log("search-\(kind.rawValue)-\(query)")
        return [SearchResult(kind: kind == .movies ? .movie : .series, remote_id: 1, title: query)]
    }
    func searchReleases(_ query: String) async throws -> [Release] {
        try log("releases-\(query)")
        return [Release(guid: "g1", indexer_id: 2, title: query)]
    }
    func discover(_ kind: MediaKind) async throws -> [SearchResult] {
        try log("discover-\(kind.rawValue)")
        return [SearchResult(kind: .movie, remote_id: 9, title: "Popular")]
    }
    func grab(guid: String, indexerID: Int) async throws { try log("grab-\(guid)-\(indexerID)") }
    func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?) async throws {
        try log("add-\(result.remote_id)-\(qualityProfile)-\(rootFolder)")
    }
    func collections() async throws -> [Collection] {
        try log("collections")
        return [Collection(id: 1, monitored: false, title: "Alien"), Collection(id: 2, title: "Bond")]
    }
    func collectionDetail(_ id: Int) async throws -> CollectionDetail { try log("collection-\(id)"); return .init(id: id) }
    func setCollectionMonitored(_ id: Int, _ monitored: Bool) async throws { try log("collection-\(id)-\(monitored)") }
    func popular(hours: Int, limit: Int) async throws -> Block<PopularSnapshot> {
        try log("popular-\(hours)-\(limit)")
        return .healthy(.init(hours: hours, indexers: [
            .init(indexer: "NB", indexer_id: 1, releases: [
                .init(grabs: 5, guid: "a", indexer_id: 1, kind: "movie", title: "Film"),
                .init(grabs: 3, guid: "b", indexer_id: 1, kind: "tv", title: "Show"),
            ], scanned: 100),
        ]))
    }

    func movieDetail(_ id: Int) async throws -> MovieDetail { .init(id: id) }
    func movieCredits(_ id: Int) async throws -> Credits { .init() }
    func seriesDetail(_ id: Int) async throws -> SeriesDetail { .init(id: id, seasons: []) }
    func bookDetail(_ id: Int) async throws -> BookDetail { .init(id: id) }
    func episodes(series: Int, season: Int) async throws -> [Episode] { [] }
    func options(_ app: ArrApp) async throws -> Options {
        try log("options-\(app.rawValue)")
        return .init(quality_profiles: [.init(id: 4, name: "HD"), .init(id: 1, name: "Any")],
                     root_folders: [.init(free_space: 10, id: 1, path: "/movies")])
    }
    func watched() async throws -> Block<WatchedMap> { .healthy(.init()) }
    func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws { try log("update-\(ref.id)") }
    func delete(_ ref: MediaRef, deleteFiles: Bool) async throws { try log("delete-\(ref.id)") }
    func triggerSearch(_ ref: MediaRef) async throws { try log("trigger-\(ref.id)") }
    func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {}
    func searchSeason(series: Int, season: Int) async throws {}
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {}
    func searchEpisodes(_ ids: [Int]) async throws {}
}

@MainActor
@Suite struct AddModelTests {
    @Test func tabsFollowConfiguredServicesAndDiscoverNeedsOverseerr() async {
        let api = FakeDiscoverAPI()
        let model = AddModel(configured: ["radarr", "prowlarr"], api: api, onSessionLost: {})
        #expect(model.tabs == [.movies, .collections, .releases])
        #expect(!model.canDiscover)
        await model.load()
        #expect(await api.count("discover-movies") == 0)

        let withOverseerr = AddModel(configured: ["radarr", "sonarr", "overseerr"], api: api, onSessionLost: {})
        await withOverseerr.load()
        #expect(withOverseerr.discover[.movies]?.value?.first?.title == "Popular")
        await withOverseerr.load()
        #expect(await api.count("discover-movies") == 1, "popular is fetched once per screen life")
    }

    @Test func typingIsDebouncedAndTabChangeClears() async throws {
        let api = FakeDiscoverAPI()
        let model = AddModel(configured: ["radarr", "sonarr", "prowlarr"], api: api, onSessionLost: {})
        model.input = "s"
        #expect(!model.searching, "one character is not a query")
        model.input = "sl"
        model.input = "slow"
        try await Task.sleep(for: .milliseconds(700))
        #expect(await api.count("search-movies-slow") == 1)
        #expect(await api.calls.filter { $0.hasPrefix("search-") }.count == 1)
        #expect(model.results?.value?.first?.title == "slow")

        model.tab = .series
        #expect(model.input == "")
        #expect(model.results == nil)

        // releases are submit-only
        model.tab = .releases
        model.input = "ubuntu"
        try await Task.sleep(for: .milliseconds(600))
        #expect(await api.count("releases-ubuntu") == 0)
        await model.submit()
        #expect(model.releases?.value?.first?.guid == "g1")
        await model.grab(model.releases!.value![0])
        #expect(await api.count("grab-g1-2") == 1)
        #expect(model.grabbed.contains("g1"))
    }

    @Test func collectionsFilterLocallyAndToggleRefetches() async {
        let api = FakeDiscoverAPI()
        let model = AddModel(configured: ["radarr"], api: api, onSessionLost: {})
        model.tab = .collections
        await model.load()
        #expect(model.shownCollections.map(\.title) == ["Alien", "Bond"])
        model.input = "bo"
        #expect(model.shownCollections.map(\.title) == ["Bond"])
        // switching to the tab already fetched once; the toggle refetches
        let before = await api.count("collections")
        await model.setCollectionMonitored(model.shownCollections[0], true)
        #expect(await api.count("collection-2-true") == 1)
        #expect(await api.count("collections") == before + 1)
    }

    @Test func mediaSheetDefaultsAndAdds() async {
        let api = FakeDiscoverAPI()
        let result = SearchResult(kind: .movie, remote_id: 77, title: "New")
        let sheet = MediaSheetModel(result: result, api: api, onSessionLost: {})
        #expect(!sheet.canAdd)
        await sheet.load()
        #expect(sheet.qualityProfile == 4)
        #expect(sheet.rootFolder == "/movies")
        #expect(sheet.canAdd)
        await sheet.add()
        #expect(await api.count("add-77-4-/movies") == 1)
        #expect(sheet.done)

        let owned = SearchResult(in_library: true, kind: .series, library_id: 63, monitored: true, quality_profile_id: 1, remote_id: 1, title: "Have")
        let edit = MediaSheetModel(result: owned, api: api, onSessionLost: {})
        await edit.load()
        #expect(edit.qualityProfile == 1, "the library's own profile wins over the default")
        await edit.setMonitored(false)
        #expect(await api.count("update-63") == 1)
        #expect(edit.done)
    }

    @Test func popularFiltersByKindAndGrabs() async {
        let api = FakeDiscoverAPI()
        let model = PopularModel(api: api, onSessionLost: {})
        await model.load()
        let indexer = model.snapshot.value!.value!.indexers![0]
        #expect(model.releases(of: indexer).count == 2)
        model.kind = .tv
        #expect(model.releases(of: indexer).map(\.title) == ["Show"])
        await model.grab(model.releases(of: indexer)[0])
        #expect(await api.count("grab-b-1") == 1)
        #expect(model.grabbed.contains("b"))
        #expect(await api.count("popular-24-10") == 1)
    }
}
