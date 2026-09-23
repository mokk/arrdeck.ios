import Foundation
import Observation

public enum CalendarView: String, CaseIterable, Sendable, Hashable {
    case month, week, agenda

    public var label: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        case .agenda: "Agenda"
        }
    }
}

/// The window a calendar view requests. Each view steps by its own unit, so
/// `offset` means months, weeks or nothing depending on where you are; the
/// agenda is always "from today".
public struct CalendarRange: Equatable, Sendable {
    public var start: Date
    public var days: Int

    public static let agendaDays = 14

    public static func range(
        _ view: CalendarView, offset: Int, now: Date = .now, calendar: Calendar = .current
    ) -> CalendarRange {
        let today = calendar.startOfDay(for: now)
        switch view {
        case .month:
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            let first = calendar.date(byAdding: .month, value: offset, to: thisMonth)!
            let days = calendar.range(of: .day, in: .month, for: first)!.count
            return CalendarRange(start: first, days: days)
        case .week:
            let start = calendar.date(byAdding: .day, value: offset * 7, to: weekStart(today, calendar: calendar))!
            return CalendarRange(start: start, days: 7)
        case .agenda:
            return CalendarRange(start: today, days: agendaDays)
        }
    }

    /// Monday-first, matching the month grid's column order.
    public static func weekStart(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
        let back = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: date))!
    }

    /// yyyy-MM-dd, as the backend's `start_date` wants it.
    public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public var startISO: String { CalendarRange.isoDay(start) }

    public func day(_ index: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: index, to: start)!
    }
}

public protocol CalendarAPI: Sendable {
    func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>]
}

extension LiveAPI: CalendarAPI {
    public func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>] {
        try await call {
            switch try await client.calendar_api_v1_calendar_get(query: .init(days: days, start_date: start)) {
            case let .ok(ok):
                let body = try ok.body.json
                return [.radarr: Block(body.radarr), .sonarr: Block(body.sonarr)]
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension CalendarItem {
    /// The local calendar day an item lands on. A dated item without a
    /// parseable timestamp falls back to its first ten characters.
    public func day(calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        if let parsed = Format.parseDate(date) { return CalendarRange.isoDay(parsed, calendar: calendar) }
        return String(date.prefix(10))
    }
}

/// The calendar page: one requested window, grouped by local day so the month
/// grid, the week strip and the agenda all read from the same map.
@MainActor @Observable
public final class CalendarModel {
    public var view: CalendarView = .month {
        didSet { if view != oldValue { offset = 0; selectedDay = nil; Task { await load() } } }
    }
    public private(set) var offset = 0
    public var selectedDay: String?
    public private(set) var blocks: Loadable<[ArrApp: Block<[CalendarItem]>]> = .loading

    let api: any CalendarAPI
    let calendar: Calendar
    let now: () -> Date
    let onSessionLost: @MainActor () -> Void
    private var generation = 0

    public init(
        api: any CalendarAPI, calendar: Calendar = .current, now: @escaping () -> Date = { .now },
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.calendar = calendar
        self.now = now
        self.onSessionLost = onSessionLost
    }

    public var range: CalendarRange { CalendarRange.range(view, offset: offset, now: now(), calendar: calendar) }
    public var today: String { CalendarRange.isoDay(now(), calendar: calendar) }

    /// Every dated item in the window, earliest first.
    public var items: [CalendarItem] {
        (blocks.value.map { blocks in ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] } } ?? [])
            .filter { $0.date != nil }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }
    }

    public var byDay: [String: [CalendarItem]] {
        var map: [String: [CalendarItem]] = [:]
        for item in items {
            if let day = item.day(calendar: calendar) { map[day, default: []].append(item) }
        }
        return map
    }

    /// The days that have anything, in order — the agenda's sections.
    public var days: [String] { byDay.keys.sorted() }

    public var listed: [CalendarItem] {
        if let selectedDay { return byDay[selectedDay] ?? [] }
        return items
    }

    public func offlineReason(_ app: ArrApp) -> String? { blocks.value?[app]?.offlineReason }

    public func step(_ delta: Int) {
        guard view != .agenda else { return }
        offset += delta
        selectedDay = nil
        Task { await load() }
    }

    public func toggle(day: String) {
        selectedDay = selectedDay == day ? nil : day
    }

    public func load() async {
        generation += 1
        let mine = generation
        let range = range
        do {
            let result = try await api.calendar(start: range.startISO, days: range.days)
            guard mine == generation else { return }
            blocks = .loaded(result)
        } catch {
            guard mine == generation else { return }
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if blocks.value == nil {
                blocks = .failed((error as? APIError)?.description ?? error.localizedDescription)
            }
        }
    }
}
