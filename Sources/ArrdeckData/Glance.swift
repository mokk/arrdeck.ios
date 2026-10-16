import ArrdeckGlance
import Foundation

/// The widgets' snapshot from what the dashboard already polls — the torrent
/// summary, the calendar and the disks — so the widgets cost no request of
/// their own; Activity's feed is the one polled for them. Pure: the values
/// in, the snapshot out.
extension GlanceSnapshot {
    /// A section is left out (nil) while its card has no answer, so merging
    /// keeps the previous copy instead of saying "nothing downloading".
    public static func make(
        server: String,
        torrents: [TorrentClient: Block<TorrentSummary>]?,
        calendar items: [ArrApp: Block<[CalendarItem]>]?,
        disks: Block<[DiskSpace]>?,
        activity events: [ActivityEvent]? = nil,
        titles: [MediaRef: GlanceTitle] = [:],
        posters: Set<String> = [],
        byteBase: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> GlanceSnapshot {
        GlanceSnapshot(
            server: server,
            downloads: torrents.flatMap { downloads($0, now: now) },
            today: items.flatMap { today($0, now: now, calendar: calendar) },
            disk: disks.flatMap { disk($0, now: now) },
            activity: events.map { activity($0, titles: titles, posters: posters, now: now, calendar: calendar) },
            byteBase: byteBase
        )
    }

    /// qBittorrent's "no estimate" (100 days); anything past it is not a time.
    static let noEstimate = 8_640_000

    /// The summary ships each client's five busiest torrents, seeders among
    /// them (it ranks by download plus upload); keep the ones fetching. Five
    /// downloads at once is the most it can count — rare on a home stack.
    static func downloads(_ blocks: [TorrentClient: Block<TorrentSummary>], now: Date) -> Downloads? {
        let summaries = blocks.values.compactMap(\.value)
        // every client offline: say nothing rather than "nothing downloading"
        guard !summaries.isEmpty else { return nil }
        let active = summaries
            .flatMap { $0.active ?? [] }
            .filter { $0.state == "downloading" || $0.dl_speed > 0 }
            .sorted { $0.dl_speed > $1.dl_speed }
        let estimates = active.compactMap(\.eta).filter { $0 > 0 && $0 < noEstimate }
        let size = active.reduce(0) { $0 + $1.size }
        let done = active.reduce(0.0) { $0 + Double($1.size) * $1.progress }
        return Downloads(
            at: now,
            top: active.prefix(Downloads.shown).map { torrent in
                Downloads.Item(
                    name: SpokenSummary.spokenName(torrent.name), progress: torrent.progress,
                    speed: torrent.dl_speed, eta: torrent.eta.flatMap { $0 > 0 && $0 < noEstimate ? $0 : nil }
                )
            },
            count: active.count,
            // the clients' own totals: they count torrents outside the top five too
            speed: summaries.reduce(0) { $0 + $1.totals.dl_speed },
            progress: size > 0 ? done / Double(size) : nil,
            // the last to finish, when every one of them has an estimate
            eta: !active.isEmpty && estimates.count == active.count ? estimates.max() : nil
        )
    }

    static func today(_ blocks: [ArrApp: Block<[CalendarItem]>], now: Date, calendar: Calendar) -> Today? {
        let lists = blocks.values.compactMap(\.value)
        guard !lists.isEmpty else { return nil }
        let day = CalendarDay.iso(now, calendar: calendar)
        let entries = CalendarEntry.fold(
            lists.flatMap { $0 }
                .filter { $0.day(calendar: calendar) == day }
                .sorted { ($0.date ?? "") < ($1.date ?? "") }
        )
        return Today(
            at: now, day: day,
            entries: entries.prefix(Today.shown).map { entry in
                let item = entry.item
                return Today.Entry(
                    kind: kind(item.arr),
                    title: item.title,
                    code: entry.code.flatMap { $0.isEmpty ? nil : $0 },
                    // an episode airs at a moment; a release day has no time worth showing
                    time: item.arr == .sonarr ? item.date.flatMap { Format.parseDate($0) } : nil,
                    downloaded: item.has_file ?? false
                )
            },
            count: entries.count
        )
    }

    static func kind(_ arr: ArrApp?) -> Today.Entry.Kind {
        switch arr {
        case .radarr: .movie
        case .sonarr: .episode
        case .readarr: .book
        case .lidarr: .album
        // LiveAPI drops rows from arrs this build does not know
        case nil: .movie
        }
    }

    /// The arrs' events newest first, one entry per title and day: the
    /// latest event that day says where it got to (a grab, then its import,
    /// is an arrival), and a day's episodes of one show are one entry
    /// ("S01E01–E08, S02E01–E08"), or the widget would be a column of one show.
    static func activity(_ events: [ActivityEvent], titles: [MediaRef: GlanceTitle],
                         posters: Set<String>, now: Date, calendar: Calendar) -> Activity {
        struct Record {
            var event: Activity.Entry.Event
            var date: Date
            var episode: Episode?
        }
        struct Group {
            var app: String
            var ref: MediaRef?
            var release: String
            var records: [Record]
        }
        var groups: [String: Group] = [:]
        for item in events {
            // the torrent clients' "completed" says nothing a widget names
            guard ArrApp(rawValue: item.app) != nil, let event = activityEvent(item.kind.rawValue),
                  let date = Format.parseDate(item.date)
            else { continue }
            let ref = MediaRef(app: item.app, id: item.movie_id ?? item.series_id ?? item.book_id ?? item.album_id)
            let episode = item.season.flatMap { season in item.episode.map { Episode(season: season, number: $0) } }
                ?? episodeNumber(item.title)
            let id = [item.app, ref?.glanceKey ?? SpokenSummary.spokenName(item.title), CalendarDay.iso(date, calendar: calendar)]
                .joined(separator: "|")
            groups[id, default: Group(app: item.app, ref: ref, release: item.title, records: [])]
                .records.append(Record(event: event, date: date, episode: episode))
        }
        let entries = groups.values.compactMap { group -> Activity.Entry? in
            guard let latest = group.records.max(by: { $0.date < $1.date }) else { return nil }
            // what the latest event says, for the episodes it happened to
            let records = group.records.filter { $0.event == latest.event }
            let episodes = Set(records.compactMap(\.episode))
            let title = group.ref.flatMap { titles[$0]?.title } ?? SpokenSummary.spokenName(group.release)
            let key = group.ref?.glanceKey
            return Activity.Entry(
                kind: activityKind(ArrApp(rawValue: group.app)), event: latest.event,
                title: title.isEmpty ? group.release : title,
                code: episodeCode(episodes),
                count: episodes.isEmpty ? records.count : episodes.count,
                date: latest.date, key: key, hasPoster: key.map(posters.contains) ?? false
            )
        }
        .sorted { $0.date > $1.date }
        return Activity(at: now, entries: Array(entries.prefix(Activity.shown)))
    }

    struct Episode: Hashable, Comparable {
        var season: Int
        var number: Int

        static func < (a: Episode, b: Episode) -> Bool { (a.season, a.number) < (b.season, b.number) }
    }

    static func activityEvent(_ type: String) -> Activity.Entry.Event? {
        switch type {
        case "imported": .arrived
        case "failed": .failed
        case "fetched": .grabbed
        // deleted, and Readarr's "incomplete" on the way to an import
        default: nil
        }
    }

    static func activityKind(_ arr: ArrApp?) -> Activity.Entry.Kind {
        switch arr {
        case .radarr, nil: .movie
        case .sonarr: .episode
        case .readarr: .book
        case .lidarr: .album
        }
    }

    /// S02E08 in a release name, as numbers.
    static func episodeNumber(_ release: String) -> Episode? {
        guard let match = release.firstMatch(of: /(?i)(?:^|[^a-z0-9])s(\d{1,2})e(\d{1,3})/),
              let season = Int(match.1), let number = Int(match.2)
        else { return nil }
        return Episode(season: season, number: number)
    }

    /// Each season's episodes: a run as "S02E02–E08", single ones listed
    /// ("S02E01, E04"), seasons one after another. Nil with no numbers known.
    static func episodeCode(_ episodes: Set<Episode>) -> String? {
        guard !episodes.isEmpty else { return nil }
        let seasons = Dictionary(grouping: episodes.sorted(), by: \.season).sorted { $0.key < $1.key }
        return seasons.map { season, episodes in
            let numbers = episodes.map(\.number)
            var runs: [ClosedRange<Int>] = []
            for number in numbers {
                if let last = runs.last, last.upperBound + 1 == number {
                    runs[runs.count - 1] = last.lowerBound...number
                } else {
                    runs.append(number...number)
                }
            }
            let parts = runs.map { run in
                run.count == 1 ? String(format: "E%02d", run.lowerBound) : String(format: "E%02d–E%02d", run.lowerBound, run.upperBound)
            }
            return String(format: "S%02d", season) + parts.joined(separator: ", ")
        }
        .joined(separator: ", ")
    }

    /// The root folder with the least room left — what fills up first. Paths
    /// on one volume report the same numbers, which the minimum absorbs.
    static func disk(_ block: Block<[DiskSpace]>, now: Date) -> Disk? {
        guard let fullest = (block.value ?? [])
            .filter({ $0.free_bytes != nil })
            .min(by: { ($0.free_bytes ?? 0) < ($1.free_bytes ?? 0) })
        else { return nil }
        let total = fullest.total_bytes.flatMap { $0 > 0 ? $0 : nil }
        return Disk(at: now, free: fullest.free_bytes ?? 0, total: total, label: fullest.label)
    }
}

/// A title the app has loaded from a library: what the Activity widget calls
/// a history row, and where its poster is.
public struct GlanceTitle: Sendable, Equatable {
    public var title: String
    public var poster: String?

    public init(title: String, poster: String?) {
        self.title = title
        self.poster = poster
    }
}

extension MediaRef {
    /// The name of this title's poster in the widgets' container: movie-207.
    public var glanceKey: String {
        switch self {
        case let .movie(id): "movie-\(id)"
        case let .series(id): "series-\(id)"
        case let .book(id): "book-\(id)"
        case let .artist(id): "artist-\(id)"
        case let .album(id): "album-\(id)"
        }
    }
}
