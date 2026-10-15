import ArrdeckData
import Foundation

extension DirectBackend: ActivityAPI {
    /// What happened since the Activity tab was last opened: imports,
    /// failures and grabs from the arrs, finished torrents from the clients.
    /// A service that is down adds nothing rather than badging nothing.
    public func activitySince(_ since: Date) async throws -> ActivitySince {
        async let radarr = activityEvents(.radarr, since: since)
        async let sonarr = activityEvents(.sonarr, since: since)
        async let readarr = activityEvents(.readarr, since: since)
        async let lidarr = activityEvents(.lidarr, since: since)
        async let qbittorrent = finishedTorrents(.qbittorrent, since: since)
        async let transmission = finishedTorrents(.transmission, since: since)
        let all = await radarr + sonarr + readarr + lidarr + qbittorrent + transmission
        let newest = DashboardPort.stableSorted(all) { $0.at > $1.at }.map(\.event)
        return ActivitySince(
            count: newest.count, items: Array(newest.prefix(200)),
            now: DashboardPort.iso(.now), since: DashboardPort.iso(since)
        )
    }

    private func activityEvents(_ app: ArrApp, since: Date) async -> [(at: Date, event: ActivityEvent)] {
        guard registry.isConfigured(app.rawValue), let client = try? registry.arr(app.rawValue),
              // Sonarr's records name the episode only when asked
              let payload = try? await DashboardPort.history(
                  client, app: app, pageSize: 100, extra: app == .sonarr ? ["includeEpisode": "true"] : [:]
              )
        else { return [] }
        return Self.activityEvents(app: app, records: payload["records"].array, since: since)
    }

    /// History events worth a badge. Renames, deletes and ignores are noise
    /// here.
    private static let notableActivity: Set = ["imported", "failed", "fetched", "incomplete"]

    private static func activityEvents(app: ArrApp, records: [JSON], since: Date) -> [(at: Date, event: ActivityEvent)] {
        // Lidarr records an import per track, plus one for the download as a
        // whole: an album is one thing that happened, not a dozen
        var seen: Set<String> = []
        return records.compactMap { record -> (at: Date, event: ActivityEvent)? in
            guard let at = record["date"].date, at > since else { return nil }
            let label = DashboardPort.label(record)
            guard notableActivity.contains(label), let kind = ActivityEvent.kindPayload(rawValue: label) else { return nil }
            if app == .lidarr, !seen.insert("\(label)|\(DashboardPort.historyKey(app: app, record: record))").inserted {
                return nil
            }
            let episode = app == .sonarr && DashboardPort.truthy(record["episode"]) ? record["episode"] : .null
            return (at, ActivityEvent(
                album_id: app == .lidarr ? record["albumId"].int : nil,
                app: app.rawValue,
                book_id: record["bookId"].int,
                date: DashboardPort.iso(at),
                episode: episode["episodeNumber"].int,
                kind: kind,
                movie_id: record["movieId"].int,
                season: episode["seasonNumber"].int,
                series_id: record["seriesId"].int,
                title: app == .lidarr ? DashboardPort.albumTitle(record) : record["sourceTitle"].string ?? ""
            ))
        }
    }

    private func finishedTorrents(_ client: TorrentClient, since: Date) async -> [(at: Date, event: ActivityEvent)] {
        guard registry.isConfigured(client.rawValue) else { return [] }
        switch client {
        case .qbittorrent:
            guard let qbittorrent = try? registry.qbittorrent(),
                  let torrents = try? await DashboardPort.qbittorrentTorrents(qbittorrent) else { return [] }
            return Self.finishedTorrents(client, torrents, since: since, done: "completion_on")
        case .transmission:
            guard let transmission = try? registry.transmission(),
                  let torrents = try? await DashboardPort.transmissionTorrents(transmission) else { return [] }
            return Self.finishedTorrents(client, torrents, since: since, done: "doneDate")
        }
    }

    /// Torrents that finished after the mark. The clients count completion in
    /// unix seconds; unfinished ones have none, 0 or -1.
    private static func finishedTorrents(
        _ client: TorrentClient, _ torrents: [JSON], since: Date, done key: String
    ) -> [(at: Date, event: ActivityEvent)] {
        torrents.compactMap { torrent -> (at: Date, event: ActivityEvent)? in
            let done = torrent[key].double ?? 0
            guard done > since.timeIntervalSince1970 else { return nil }
            let at = Date(timeIntervalSince1970: done)
            return (at, ActivityEvent(
                app: client.rawValue, date: DashboardPort.iso(at), kind: .completed, title: torrent["name"].string ?? ""
            ))
        }
    }
}
