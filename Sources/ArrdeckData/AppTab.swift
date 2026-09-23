import Foundation

/// The bottom bar. Each tab exists only while the service behind it is
/// configured, so a stack without Readarr never shows Books and one without
/// a download client or an arr never shows Activity.
public enum AppTab: String, CaseIterable, Sendable, Hashable {
    case books, movies, shows, activity, calendar, settings

    public var label: String {
        switch self {
        case .books: String(localized: "Books")
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "Shows")
        case .activity: String(localized: "Activity")
        case .calendar: String(localized: "Calendar")
        case .settings: String(localized: "Settings")
        }
    }

    public var symbol: String {
        switch self {
        case .books: "books.vertical"
        case .movies: "film"
        case .shows: "tv"
        case .activity: "arrow.up.arrow.down"
        case .calendar: "calendar"
        case .settings: "gearshape"
        }
    }

    /// The tabs in the order and selection chosen under Settings → Display.
    /// Tabs missing from the saved order keep their natural place after the
    /// ordered ones; Settings can never be hidden.
    public static func arrange(_ tabs: [AppTab], order: [AppTab], hidden: Set<AppTab>) -> [AppTab] {
        func rank(_ tab: AppTab) -> Int { order.firstIndex(of: tab) ?? order.count + (tabs.firstIndex(of: tab) ?? 0) }
        return tabs.filter { $0 == .settings || !hidden.contains($0) }.sorted { rank($0) < rank($1) }
    }

    /// Parses the comma-separated form the preferences store.
    public static func list(_ raw: String) -> [AppTab] {
        raw.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }
    }

    /// Which tabs a backend with these services configured shows, in order.
    public static func available(configured: Set<String>) -> [AppTab] {
        let hasArr = configured.contains("radarr") || configured.contains("sonarr") || configured.contains("readarr")
        let hasClient = configured.contains("qbittorrent") || configured.contains("transmission")
        return allCases.filter { tab in
            switch tab {
            case .books: configured.contains("readarr")
            case .movies: configured.contains("radarr")
            case .shows: configured.contains("sonarr")
            case .activity: hasArr || hasClient
            case .calendar: hasArr
            case .settings: true
            }
        }
    }
}

extension LibraryRow {
    /// The card's dot: green when everything is on disk, blue when wanted,
    /// orange when nobody is looking for it.
    public enum Dot: Sendable { case complete, wanted, unmonitored }

    public var dot: Dot {
        guard monitored else { return .unmonitored }
        switch ref {
        case .movie, .book: return status == "downloaded" ? .complete : .wanted
        case .series: return (episodeFiles ?? 0) >= (episodes ?? 0) && (episodes ?? 0) > 0 ? .complete : .wanted
        }
    }
}

extension DashboardModel {
    /// Download progress per library title, from the arr queue the dashboard
    /// already polls — what puts a bar under a poster.
    public var queueProgress: [MediaRef: Double] {
        var out: [MediaRef: Double] = [:]
        let blocks: [Block<[QueueItem]>] = queue.value.map { Array($0.values) } ?? []
        for block in blocks {
            for item in block.value ?? [] {
                let ref: MediaRef? = if let movie = item.movie_id { .movie(movie) } else if let series = item.series_id { .series(series) } else if let book = item.book_id { .book(book) } else { nil }
                guard let ref, item.size > 0 else { continue }
                let progress = (item.size - item.size_left) / item.size
                out[ref] = max(out[ref] ?? 0, progress)
            }
        }
        return out
    }
}
