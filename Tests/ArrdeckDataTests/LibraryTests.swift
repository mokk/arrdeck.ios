import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct LibraryTests {
    @Test func refsComeFromTheRightIds() {
        #expect(RecentItem(app: .sonarr, date: "", library_id: 63, title: "x").ref == .series(63))
        #expect(RecentItem(app: .radarr, date: "", library_id: nil, title: "x").ref == nil)
        #expect(HistoryItem(app: .radarr, date: "", movie_id: 180, title: "x").ref == .movie(180))
        #expect(HistoryItem(app: .sonarr, date: "", series_id: 7, title: "x").ref == .series(7))
        #expect(MediaRef.movie(1).app == .radarr)
        #expect(MediaRef.series(2).id == 2)
    }

    @Test func watchedTriesEachIdAndComposesTheLink() {
        let map = WatchedMap(
            base_url: "https://app.plex.tv/#!/server/abc/details?key=",
            items: .init(additionalProperties: [
                "tvdb:376098": .init(key: "%2Flibrary%2Fmetadata%2F9", progress: 0.5, watched: false),
                "imdb:tt1": .init(key: nil, progress: 1, watched: true),
            ])
        )
        let hit = Watched.lookup(map, tmdb: 95350, tvdb: 376098, imdb: "tt26545992")
        #expect(hit?.progress == 0.5)
        #expect(hit?.url?.absoluteString == "https://app.plex.tv/#!/server/abc/details?key=%2Flibrary%2Fmetadata%2F9")
        let noKey = Watched.lookup(map, imdb: "tt1")
        #expect(noKey?.watched == true)
        #expect(noKey?.url == nil)
        #expect(Watched.lookup(map, tmdb: 1) == nil)
        #expect(Watched.lookup(nil, tmdb: 1) == nil)
    }

    @Test func externalLinksFollowTheIds() {
        let movie = MovieDetail(id: 1, imdb_id: "tt35298123", tmdb_id: 1240889)
        let plex = Watched(watched: true, progress: 1, url: URL(string: "https://plex/x"))
        #expect(ExternalLink.links(for: movie, watched: plex).map(\.label) == ["Plex", "IMDb", "TMDB"])
        #expect(ExternalLink.links(for: MovieDetail(id: 1), watched: nil).isEmpty)
        let series = SeriesDetail(id: 63, seasons: [], tvdb_id: 376098)
        #expect(ExternalLink.links(for: series, watched: nil).map(\.url.absoluteString)
            == ["https://www.thetvdb.com/dereferrer/series/376098"])
    }
}

actor FakeLibraryAPI: LibraryAPI {
    var movie = MovieDetail(has_file: true, id: 180, monitored: true, quality_profile_id: 4, title: "Film", tmdb_id: 1)
    var series = SeriesDetail(id: 63, monitored: true, seasons: [.init(monitored: true, number: 1)], title: "Show")
    var episodeList = [Episode(episode: 1, has_file: false, id: 4404, monitored: true, season: 1, title: "Pilot")]
    var failure: APIError?
    private(set) var calls: [String] = []

    func set(failure: APIError?) { self.failure = failure }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
    private func log(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func movieDetail(_ id: Int) async throws -> MovieDetail { try log("movie"); return movie }
    func movieCredits(_ id: Int) async throws -> Credits { try log("credits"); return .init(cast: [.init(name: "A B")]) }
    func seriesDetail(_ id: Int) async throws -> SeriesDetail { try log("series"); return series }
    func bookDetail(_ id: Int) async throws -> BookDetail { try log("book"); return .init(id: id, title: "Book") }
    func episodes(series: Int, season: Int) async throws -> [Episode] { try log("episodes-\(season)"); return episodeList }
    func options(_ app: ArrApp) async throws -> Options {
        try log("options-\(app.rawValue)")
        return .init(quality_profiles: [.init(id: 4, name: "HD")], root_folders: [])
    }
    func watched() async throws -> Block<WatchedMap> { try log("watched"); return .healthy(.init()) }
    func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws {
        try log("update-\(ref.id)-\(monitored.map(String.init) ?? "_")-\(qualityProfile.map(String.init) ?? "_")")
        if let monitored { movie.monitored = monitored }
    }
    func delete(_ ref: MediaRef, deleteFiles: Bool) async throws { try log("delete-\(ref.id)-\(deleteFiles)") }
    func triggerSearch(_ ref: MediaRef) async throws { try log("search-\(ref.id)") }
    func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws { try log("season-monitor-\(season)-\(monitored)") }
    func searchSeason(series: Int, season: Int) async throws { try log("season-search-\(season)") }
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws { try log("ep-monitor-\(ids.first ?? 0)-\(monitored)") }
    func searchEpisodes(_ ids: [Int]) async throws { try log("ep-search-\(ids.first ?? 0)") }
}

@MainActor
@Suite struct DetailModelTests {
    @Test func movieLoadsEverythingAndOnlyAsksPlexWhenConfigured() async {
        let api = FakeLibraryAPI()
        let model = MovieDetailModel(id: 180, api: api, hasPlex: false, onSessionLost: {})
        await model.load()
        #expect(model.movie.value?.title == "Film")
        #expect(model.credits?.cast?.first?.name == "A B")
        #expect(model.qualityProfiles.map(\.name) == ["HD"])
        #expect(await api.count("options-radarr") == 1)
        #expect(await api.count("watched") == 0)

        let plexModel = MovieDetailModel(id: 180, api: api, hasPlex: true, onSessionLost: {})
        await plexModel.load()
        #expect(await api.count("watched") == 1)
    }

    @Test func actionsRefetchAndDeleteMarksTheTitleGone() async {
        let api = FakeLibraryAPI()
        let model = MovieDetailModel(id: 180, api: api, hasPlex: false, onSessionLost: {})
        await model.load()

        await model.setMonitored(false)
        #expect(await api.count("update-180-false-_") == 1)
        #expect(model.movie.value?.monitored == false, "the detail is refetched after the change")

        await model.setQualityProfile(2)
        #expect(await api.count("update-180-_-2") == 1)

        await model.search()
        #expect(await api.count("search-180") == 1)

        #expect(!model.deleted)
        await model.delete(deleteFiles: true)
        #expect(await api.count("delete-180-true") == 1)
        #expect(model.deleted)
    }

    @Test func refusedActionsReportAndKeepTheTitle() async {
        let api = FakeLibraryAPI()
        let model = MovieDetailModel(id: 180, api: api, hasPlex: false, onSessionLost: {})
        await model.load()
        await api.set(failure: .unexpectedStatus(409))
        await model.delete(deleteFiles: false)
        #expect(!model.deleted)
        #expect(model.actionError == "HTTP 409")
        #expect(model.movie.value != nil, "a failed refetch keeps what was loaded")
    }

    @Test func seriesExpandsSeasonsOnDemand() async {
        let api = FakeLibraryAPI()
        let model = SeriesDetailModel(id: 63, api: api, hasPlex: false, onSessionLost: {})
        await model.load()
        #expect(model.series.value?.seasons.count == 1)
        #expect(model.episodes.isEmpty)

        await model.toggle(season: 1)
        #expect(model.expanded == [1])
        #expect(model.episodes[1]?.value?.first?.title == "Pilot")
        await model.toggle(season: 1)
        #expect(model.expanded.isEmpty)
        await model.toggle(season: 1)
        #expect(await api.count("episodes-1") == 1, "already fetched episodes are kept")

        let episode = model.episodes[1]!.value!.first!
        await model.setEpisodeMonitored(episode, false)
        #expect(await api.count("ep-monitor-4404-false") == 1)
        #expect(await api.count("episodes-1") == 2, "the season is refetched after an episode change")
        await model.searchEpisode(episode)
        #expect(await api.count("ep-search-4404") == 1)

        let season = model.series.value!.seasons[0]
        await model.setSeasonMonitored(season, false)
        #expect(await api.count("season-monitor-1-false") == 1)
        #expect(await api.count("series") == 2)
        await model.searchSeason(season)
        #expect(await api.count("season-search-1") == 1)
    }

    @Test func unauthorizedReportsOnce() async {
        let api = FakeLibraryAPI()
        await api.set(failure: .unauthorized)
        var lost = 0
        let model = SeriesDetailModel(id: 63, api: api, hasPlex: false, onSessionLost: { lost += 1 })
        await model.load()
        #expect(lost >= 1)
        #expect(model.series == .loading, "a 401 is not a load failure to render")
    }
}
