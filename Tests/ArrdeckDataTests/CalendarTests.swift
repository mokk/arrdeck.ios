import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

actor FakeCalendarAPI: CalendarAPI {
    var items: [CalendarItem]
    var failure: APIError?
    private(set) var requests: [(String, Int)] = []
    init(items: [CalendarItem]) { self.items = items }
    func set(failure: APIError?) { self.failure = failure }
    func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>] {
        requests.append((start, days))
        if let failure { throw failure }
        return [.radarr: .healthy(items.filter { $0.app == .radarr }), .sonarr: .healthy(items.filter { $0.app == .sonarr })]
    }
}

@MainActor
@Suite struct CalendarModelTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    let now = Date(timeIntervalSince1970: 1_790_139_600) // 2026-09-23

    func model(_ api: FakeCalendarAPI) -> CalendarModel {
        CalendarModel(api: api, calendar: utc, now: { now }, onSessionLost: {})
    }

    @Test func groupsByDayOpensAtTodayAndFoldsASeasonDrop() async {
        let api = FakeCalendarAPI(items: [
            .init(app: .sonarr, date: "2026-09-25T04:00:00Z", extra: "S01E01 Pilot", item_id: 5, title: "Neagley"),
            .init(app: .sonarr, date: "2026-09-25T04:00:00Z", extra: "S01E02 Two", finale_type: nil, item_id: 5, title: "Neagley"),
            .init(app: .sonarr, date: "2026-09-25T04:00:00Z", extra: "S01E08 Eight", finale_type: "season", has_file: true, item_id: 5, title: "Neagley"),
            .init(app: .radarr, date: "2026-09-29T00:00:00Z", release_type: "digital", title: "Spider-Man"),
            .init(app: .sonarr, date: nil, title: "Undated"),
        ])
        let model = model(api)
        await model.load()
        #expect(model.days.map(\.day) == ["2026-09-23", "2026-09-25", "2026-09-29"], "today is there even when empty")
        #expect(model.days[0].entries.isEmpty)
        let drop = model.days[1].entries
        #expect(drop.count == 1 && drop[0].count == 3)
        #expect(drop[0].code == "S01E01–E08")
        #expect(drop[0].item.finale_type == "season")
        #expect(drop[0].item.has_file == false, "on disk only when every episode is")
        let first = await api.requests.first
        #expect(first?.0 == "2026-09-09" && first?.1 == 74, "two weeks back, two months ahead")
    }

    @Test func widensBothWays() async {
        let api = FakeCalendarAPI(items: [])
        let model = model(api)
        await model.load()
        await model.showEarlier()
        #expect(await api.requests.last?.0 == "2026-08-10")
        await model.showLater()
        #expect(await api.requests.last?.1 == 134)
    }

    @Test func aSingleEpisodeKeepsItsTitle() {
        let entry = CalendarEntry.fold([.init(app: .sonarr, date: "2026-09-25T04:00:00Z", extra: "S06E03 Resurrection", item_id: 1, title: "Slow Horses")])
        #expect(entry.first?.code == "S06E03" && entry.first?.episodeTitle == "Resurrection")
    }

    @Test func filtersByAppAndDownloadedAndOpensTheTitle() async {
        let api = FakeCalendarAPI(items: [
            .init(app: .sonarr, date: "2026-09-23T04:00:00Z", has_file: true, item_id: 7, title: "Slow Horses"),
            .init(app: .radarr, date: "2026-09-29T00:00:00Z", item_id: 3, title: "Spider-Man"),
        ])
        let model = model(api)
        defer {
            model.hiddenApps = []
            model.hideDownloaded = false
        }
        await model.load()
        #expect(model.apps == [.radarr, .sonarr])
        model.hiddenApps = [.radarr]
        #expect(model.items.map(\.title) == ["Slow Horses"])
        model.hiddenApps = []
        model.hideDownloaded = true
        #expect(model.items.map(\.title) == ["Spider-Man"])
        #expect(model.items.first?.ref == .movie(3))
        #expect(CalendarItem(app: .sonarr, item_id: 7, title: "x").ref == .series(7))
        #expect(CalendarItem(app: .readarr, title: "no id").ref == nil)
    }

    @Test func failuresAndUnauthorized() async {
        let api = FakeCalendarAPI(items: [])
        await api.set(failure: .unexpectedStatus(500))
        let model = model(api)
        await model.load()
        #expect(model.blocks == .failed("HTTP 500"))

        await api.set(failure: .unauthorized)
        var lost = 0
        let gone = CalendarModel(api: api, calendar: utc, now: { now }, onSessionLost: { lost += 1 })
        await gone.load()
        #expect(lost == 1)
    }
}
