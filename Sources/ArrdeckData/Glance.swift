import ArrdeckGlance
import Foundation

/// The widgets' snapshot from what the dashboard already polls — the torrent
/// summary, the calendar and the disks — so the widgets cost no request of
/// their own. Pure: the model's values in, the snapshot out.
extension GlanceSnapshot {
    /// A section is left out (nil) while its card has no answer, so merging
    /// keeps the previous copy instead of saying "nothing downloading".
    public static func make(
        server: String,
        torrents: [TorrentClient: Block<TorrentSummary>]?,
        calendar items: [ArrApp: Block<[CalendarItem]>]?,
        disks: Block<[DiskSpace]>?,
        byteBase: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> GlanceSnapshot {
        GlanceSnapshot(
            server: server,
            downloads: torrents.flatMap { downloads($0, now: now) },
            today: items.flatMap { today($0, now: now, calendar: calendar) },
            disk: disks.flatMap { disk($0, now: now) },
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
                    kind: item.arr == .sonarr ? .episode : item.arr == .radarr ? .movie : .book,
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
