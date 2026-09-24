import ArrdeckData
import Testing

actor RecordingCleanupAPI: CleanupAPI, SeasonRemoveAPI {
    private(set) var calls: [String] = []

    func cleanup(watchedDays: Int) async throws -> CleanupLists { CleanupLists() }
    func deleteForCleanup(_ app: ArrApp, ids: [Int], exclude: Bool) async throws {
        calls.append("delete-\(app.rawValue)-\(ids.map(String.init).joined(separator: ","))")
    }
    func removeSeasons(series: Int, seasons: [Int]) async throws {
        calls.append("seasons-\(series)-\(seasons.map(String.init).joined(separator: ","))")
    }
}

@Suite @MainActor struct CleanupSeasonsTests {
    let show = CleanupItem(
        id: 7, kind: .series,
        seasons: [.init(files: 8, number: 1, size: 100), .init(files: 8, number: 2, size: 200), .init(files: 8, number: 3, size: 300)],
        size: 600
    )

    @Test func aTickedShowGoesWholeUntilASeasonIsKept() {
        let model = CleanupModel(api: RecordingCleanupAPI())
        model.toggle(show)
        #expect(!model.isPartial(show))
        #expect(model.reclaim == 600)
        model.toggleSeason(show, 1)
        #expect(model.isPartial(show))
        #expect(model.seasons(of: show) == [2, 3])
        #expect(model.reclaim == 500)
        #expect(model.partials.map(\.id) == [7])
    }

    @Test func keepingEverySeasonUnticksTheShow() {
        let model = CleanupModel(api: RecordingCleanupAPI())
        model.toggle(show)
        for number in [1, 2, 3] { model.toggleSeason(show, number) }
        #expect(model.chosen.isEmpty)
        model.toggle(show)
        #expect(!model.isPartial(show), "ticking again starts from the whole show")
    }

    @Test func partShowsLoseSeasonsAndTheRestGoWhole() async {
        let api = RecordingCleanupAPI()
        let model = CleanupModel(api: api)
        let other = CleanupItem(id: 8, kind: .series, size: 50)
        let film = CleanupItem(id: 3, kind: .movie, size: 10)
        model.toggle(show)
        model.toggle(other)
        model.toggle(film)
        model.toggleSeason(show, 2)
        await model.deleteChosen(exclude: false)
        let calls = await api.calls
        #expect(calls.contains("seasons-7-1,3"))
        #expect(calls.contains("delete-sonarr-8"), "the show losing seasons is not deleted whole")
        #expect(calls.contains("delete-radarr-3"))
        #expect(model.chosen.isEmpty && model.seasonPicks.isEmpty)
    }
}
