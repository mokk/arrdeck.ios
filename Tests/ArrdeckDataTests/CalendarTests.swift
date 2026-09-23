import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct CalendarRangeTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // Wednesday 2026-09-23 05:00 UTC
    let now = Date(timeIntervalSince1970: 1_790_139_600)

    @Test func monthWindowsStepByMonth() {
        let this = CalendarRange.range(.month, offset: 0, now: now, calendar: utc)
        #expect(CalendarRange.isoDay(this.start, calendar: utc) == "2026-09-01")
        #expect(this.days == 30)
        let next = CalendarRange.range(.month, offset: 1, now: now, calendar: utc)
        #expect(CalendarRange.isoDay(next.start, calendar: utc) == "2026-10-01")
        #expect(next.days == 31)
        let feb = CalendarRange.range(.month, offset: 5, now: now, calendar: utc)
        #expect(feb.days == 28)
    }

    @Test func weeksStartOnMonday() {
        let week = CalendarRange.range(.week, offset: 0, now: now, calendar: utc)
        #expect(CalendarRange.isoDay(week.start, calendar: utc) == "2026-09-21")
        #expect(week.days == 7)
        #expect(CalendarRange.isoDay(CalendarRange.range(.week, offset: -1, now: now, calendar: utc).start, calendar: utc) == "2026-09-14")
        // a Sunday belongs to the week that started six days earlier
        let sunday = Date(timeIntervalSince1970: 1_790_485_200) // 2026-09-27
        #expect(CalendarRange.isoDay(CalendarRange.weekStart(sunday, calendar: utc), calendar: utc) == "2026-09-21")
    }

    @Test func agendaIsFromTodayRegardlessOfOffset() {
        let agenda = CalendarRange.range(.agenda, offset: 3, now: now, calendar: utc)
        #expect(CalendarRange.isoDay(agenda.start, calendar: utc) == "2026-09-23")
        #expect(agenda.days == 14)
    }
}

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

    @Test func groupsByLocalDayAndNarrowsOnSelection() async {
        let api = FakeCalendarAPI(items: [
            .init(app: .sonarr, date: "2026-09-23T04:00:00Z", extra: "S06E02", title: "Slow Horses"),
            .init(app: .radarr, date: "2026-09-29T00:00:00Z", release_type: "digital", title: "Spider-Man"),
            .init(app: .sonarr, date: "2026-09-23T23:30:00Z", title: "Late"),
            .init(app: .sonarr, date: nil, title: "Undated"),
        ])
        let model = model(api)
        await model.load()
        #expect(model.items.map(\.title) == ["Slow Horses", "Late", "Spider-Man"], "sorted, undated dropped")
        #expect(model.days == ["2026-09-23", "2026-09-29"])
        #expect(model.byDay["2026-09-23"]?.count == 2)
        #expect(model.today == "2026-09-23")

        model.toggle(day: "2026-09-29")
        #expect(model.listed.map(\.title) == ["Spider-Man"])
        model.toggle(day: "2026-09-29")
        #expect(model.listed.count == 3)
        let first = await api.requests.first
        #expect(first?.0 == "2026-09-01" && first?.1 == 30, "month view requests the whole month")
    }

    @Test func steppingAndSwitchingViewsRefetch() async throws {
        let api = FakeCalendarAPI(items: [])
        let model = model(api)
        await model.load()
        model.step(1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await api.requests.last?.0 == "2026-10-01")
        #expect(model.offset == 1)

        model.view = .week
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.offset == 0, "a view change resets the offset")
        let last = await api.requests.last
        #expect(last?.0 == "2026-09-21" && last?.1 == 7)

        model.view = .agenda
        try await Task.sleep(for: .milliseconds(100))
        model.step(1)
        #expect(model.offset == 0, "the agenda does not step")
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
