import ArrdeckData
import Foundation

extension DirectBackend: CalendarAPI {
    /// What comes out from `start` (yyyy-MM-dd) for `days` days, per arr.
    /// Each arr's answer for a window is reused for a minute; the fallback
    /// when one is down is its last answer, whatever window that was for, as
    /// the server's was.
    public func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>] {
        guard let base = CalendarDay.date(start), let last = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { throw APIError.refused("start_date must be a date (yyyy-mm-dd)") }
        let start = CalendarDay.iso(base), end = CalendarDay.iso(last)
        return await dashboardArrBlocks("calendar") { app, client in
            let entries = try await self.cached("calendar:\(app.rawValue):\(start):\(end)", ttl: 60) {
                try await client.get("/calendar", query: Self.calendarQuery(app, start: start, end: end))
            }
            return DashboardPort.calendarItems(app: app, entries: entries, start: start, end: end)
        }
    }

    /// The window, and whatever names an entry: the show, the author, the
    /// artist. A film names itself.
    private static func calendarQuery(_ app: ArrApp, start: String, end: String) -> [String: String?] {
        let include: String? = switch app {
        case .radarr: nil
        case .sonarr: "includeSeries"
        case .readarr: "includeAuthor"
        case .lidarr: "includeArtist"
        }
        var query: [String: String?] = ["start": start, "end": end]
        if let include { query[include] = "true" }
        return query
    }
}
