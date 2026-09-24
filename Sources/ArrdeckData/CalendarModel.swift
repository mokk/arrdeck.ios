import Foundation
import Observation

public enum CalendarDay {
    /// yyyy-MM-dd, as the backend's `start_date` wants it.
    public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func date(_ iso: String, calendar: Calendar = .current) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
                var out: [ArrApp: Block<[CalendarItem]>] = [.radarr: Block(body.radarr), .sonarr: Block(body.sonarr)]
                if let readarr = body.readarr { out[.readarr] = Block(readarr) }
                return out
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension CalendarItem {
    /// The library title an entry opens: the film, the episode's show, the book.
    public var ref: MediaRef? {
        guard let item_id else { return nil }
        return switch app {
        case .radarr: .movie(item_id)
        case .sonarr: .series(item_id)
        case .readarr: .book(item_id)
        }
    }

    /// The local calendar day an item lands on. An episode's air time is a
    /// moment and can cross midnight here; a film's or a book's release is a
    /// date and must not move.
    public func day(calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        if app == .sonarr, let parsed = Format.parseDate(date) { return CalendarDay.iso(parsed, calendar: calendar) }
        return String(date.prefix(10))
    }
}

/// One row of the calendar: an entry, or a show's episodes of one day folded
/// into one ("S01E01–E08 · 8 episodes") when a season drops at once.
public struct CalendarEntry: Identifiable, Sendable {
    public var item: CalendarItem
    public var count = 1
    /// S01E01 or S01E01–E08
    public var code: String?
    public var id: String { "\(item.app.rawValue)-\(item.item_id ?? -1)-\(item.date ?? "")-\(item.title)" }

    /// The episode title after the code, when there is exactly one episode.
    public var episodeTitle: String? {
        guard item.app == .sonarr, count == 1, let extra = item.extra else { return nil }
        let rest = extra.split(separator: " ", maxSplits: 1)
        return rest.count > 1 ? String(rest[1]) : nil
    }

    public static func fold(_ items: [CalendarItem]) -> [CalendarEntry] {
        var out: [CalendarEntry] = []
        for item in items {
            let code = item.app == .sonarr ? item.extra.map { String($0.split(separator: " ").first ?? "") } : nil
            if item.app == .sonarr, let i = out.firstIndex(where: { $0.item.app == .sonarr && $0.item.item_id == item.item_id }) {
                let first = out[i].code?.split(separator: "–").first.map(String.init) ?? ""
                let last = code ?? ""
                out[i].count += 1
                out[i].code = first + "–" + (last.firstIndex(of: "E").map { String(last[$0...]) } ?? last)
                out[i].item.has_file = (out[i].item.has_file ?? false) && (item.has_file ?? false)
                out[i].item.finale_type = out[i].item.finale_type ?? item.finale_type
            } else {
                out.append(CalendarEntry(item: item, code: code))
            }
        }
        return out
    }
}

/// The calendar page: one list from two weeks back to two months ahead,
/// widened by "Show earlier" and "Show later", grouped by local day.
@MainActor @Observable
public final class CalendarModel {
    public static let step = 30
    public private(set) var back = 14
    public private(set) var ahead = 60
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

    public var today: String { CalendarDay.iso(now(), calendar: calendar) }
    var startISO: String {
        CalendarDay.iso(calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now()))!, calendar: calendar)
    }

    /// Apps left out, and whether what is already on disk is left out too.
    /// Both persist: a calendar is usually opened for the same question.
    public var hiddenApps: Set<ArrApp> = CalendarModel.storedHiddenApps() {
        didSet { UserDefaults.standard.set(hiddenApps.map(\.rawValue), forKey: "calendar.hiddenApps") }
    }
    public var hideDownloaded = UserDefaults.standard.bool(forKey: "calendar.hideDownloaded") {
        didSet { UserDefaults.standard.set(hideDownloaded, forKey: "calendar.hideDownloaded") }
    }

    static func storedHiddenApps() -> Set<ArrApp> {
        Set((UserDefaults.standard.stringArray(forKey: "calendar.hiddenApps") ?? []).compactMap(ArrApp.init(rawValue:)))
    }

    /// The apps the window has an answer from, for the filter chips.
    public var apps: [ArrApp] { ArrApp.allCases.filter { blocks.value?[$0] != nil } }

    /// Every dated item in the window that passes the filters, earliest first.
    public var items: [CalendarItem] {
        (blocks.value.map { blocks in
            ArrApp.allCases.filter { !hiddenApps.contains($0) }.flatMap { blocks[$0]?.value ?? [] }
        } ?? [])
            .filter { $0.date != nil && !(hideDownloaded && $0.has_file == true) }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }
    }

    /// The days with anything on them, in order, and always today — so the
    /// list has somewhere to open at.
    public var days: [(day: String, entries: [CalendarEntry])] {
        var map: [String: [CalendarItem]] = [:]
        for item in items {
            if let day = item.day(calendar: calendar) { map[day, default: []].append(item) }
        }
        if map[today] == nil { map[today] = [] }
        return map.keys.sorted().map { ($0, CalendarEntry.fold(map[$0] ?? [])) }
    }

    public func offlineReason(_ app: ArrApp) -> String? { blocks.value?[app]?.offlineReason }

    public func showEarlier() async {
        back += Self.step
        await load()
    }

    public func showLater() async {
        ahead += Self.step
        await load()
    }

    public func load() async {
        generation += 1
        let mine = generation
        do {
            let result = try await api.calendar(start: startISO, days: back + ahead)
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
