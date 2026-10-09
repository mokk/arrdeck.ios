import Foundation

/// What Siri and the Shortcuts app say back: one or two sentences, built here
/// so the intents in the app target stay thin and the wording is testable.
/// Singular and plural are separate strings because the catalog has no plural
/// variants.
public enum SpokenSummary {
    /// Torrents that are getting somewhere, not merely seeding.
    static let downloadingStates: Set<String> = ["downloading", "checking", "queued", "stalled"]
    /// How many are named before the rest become "and 2 more".
    static let named = 3

    public static func downloading(api: any DownloadsAPI) async throws -> String {
        let groups = try await api.torrents(TorrentQuery())
        return downloading(groups.values.compactMap(\.value).flatMap(\.torrents))
    }

    public static func downloading(_ torrents: [Torrent]) -> String {
        let active = torrents
            .filter { downloadingStates.contains($0.state) || $0.dl_speed > 0 }
            .sorted { $0.dl_speed > $1.dl_speed }
        guard !active.isEmpty else { return String(localized: "Nothing is downloading.") }
        var parts = active.prefix(named).map { torrent in
            String(localized: "\(spokenName(torrent.name)) at \(Int((torrent.progress * 100).rounded())) percent")
        }
        if active.count > named { parts.append(String(localized: "\(active.count - named) more")) }
        let list = ListFormatter.localizedString(byJoining: parts)
        return active.count == 1
            ? String(localized: "One download: \(list).")
            : String(localized: "\(active.count) downloads: \(list).")
    }

    public static func today(
        api: any CalendarAPI, now: Date = .now, calendar: Calendar = .current
    ) async throws -> String {
        let today = CalendarDay.iso(now, calendar: calendar)
        // from yesterday: an episode airing at 01:00 here can carry the
        // previous date in UTC, and day(calendar:) moves it back
        let start = CalendarDay.iso(calendar.date(byAdding: .day, value: -1, to: now)!, calendar: calendar)
        let blocks = try await api.calendar(start: start, days: 2)
        return Self.today(blocks.values.compactMap(\.value).flatMap { $0 }, today: today, calendar: calendar)
    }

    public static func today(_ items: [CalendarItem], today: String, calendar: Calendar = .current) -> String {
        let entries = CalendarEntry.fold(
            items.filter { $0.day(calendar: calendar) == today }.sorted { ($0.date ?? "") < ($1.date ?? "") }
        )
        guard !entries.isEmpty else { return String(localized: "Nothing is out today.") }
        var parts = entries.prefix(named + 2).map { entry in
            entry.count > 1 ? String(localized: "\(entry.item.title), \(entry.count) episodes") : entry.item.title
        }
        if entries.count > named + 2 { parts.append(String(localized: "\(entries.count - named - 2) more")) }
        return String(localized: "Today: \(ListFormatter.localizedString(byJoining: parts)).")
    }

    /// Why there is no answer, in words for the speaker.
    public static func failure(_ error: Error) -> String {
        if case APIError.unauthorized = error {
            return String(localized: "arrdeck is signed out. Open the app and sign in again.")
        }
        return String(localized: "arrdeck could not reach the server.")
    }

    public static var noServer: String {
        String(localized: "Open arrdeck and choose a server first.")
    }

    /// A release name as it would be said: "The.Show.S03E08.1080p.WEB-GRP" is
    /// "The Show". Cut at the first season, year, resolution or source tag.
    static func spokenName(_ release: String) -> String {
        let words = release
            .replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
            .split(separator: " ")
        let marker = /^(?i)(s\d{1,2}(e\d{1,3})?|(19|20)\d\d|\d{3,4}p|\[.*|\(.*|web(-?dl|rip)?|bluray|hdtv|x26[45]|h ?26[45])$/
        var kept: [Substring] = []
        for word in words {
            if word.wholeMatch(of: marker) != nil, !kept.isEmpty { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }
}
