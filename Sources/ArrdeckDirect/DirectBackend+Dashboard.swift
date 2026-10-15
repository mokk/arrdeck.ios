import ArrdeckData
import Foundation

extension DirectBackend: DashboardAPI {
    /// Which services there are, which are set up, and where each one's own
    /// web page is, for "Open in Radarr".
    public func services() async throws -> [ServiceInfo] {
        DirectServices.all.compactMap { name in
            let configured = registry.isConfigured(name)
            guard DirectServices.listed(name, configured: configured), Services.known.contains(name) else { return nil }
            let web = configured && DirectServices.webUI.contains(name) ? registry.connection(name).url : nil
            return ServiceInfo(configured: configured, service: name, web_url: web)
        }
    }

    /// Who is watching what right now. The one card meant to be live, hence
    /// the short reuse.
    public func playSessions() async throws -> Block<[PlaySession]> {
        await guarded("sessions:block") {
            try await cached("sessions", ttl: 15) { try await DashboardCards.playSessions(try registry.plex()) }
        }
    }

    public func health() async throws -> Block<[HealthWarning]> {
        await guarded("health:block") {
            try await cached("health", ttl: 120) {
                await DashboardCards.health(
                    radarr: try? registry.arr("radarr"), sonarr: try? registry.arr("sonarr"),
                    prometheus: try? registry.prometheus()
                )
            }
        }
    }

    public func pendingRequests() async throws -> Block<[MediaRequest]> {
        await guarded("requests:pending") {
            try await cached("requests:pending:20", ttl: 60) {
                try await DashboardCards.pendingRequests(try registry.overseerr())
            }
        }
    }

    public func recent() async throws -> [RecentItem] {
        await DashboardCards.recent(registry)
    }

    public func torrentSummary() async throws -> [TorrentClient: Block<TorrentSummary>] {
        async let qbittorrent = guarded("torrents:sum:qbit") { try await qbittorrentSummary() }
        async let transmission = guarded("torrents:sum:tm") { try await transmissionSummary() }
        return [.qbittorrent: await qbittorrent, .transmission: await transmission]
    }

    public func queue() async throws -> [ArrApp: Block<[QueueItem]>] {
        await dashboardArrBlocks("queue") { app, client in
            DashboardPort.queueItems(app: app, payload: try await DashboardPort.queue(client, app: app))
        }
    }

    /// The next two weeks from today, the dashboard's strip.
    public func calendar() async throws -> [ArrApp: Block<[CalendarItem]>] {
        try await calendar(start: CalendarDay.iso(.now), days: 14)
    }

    public func diskSpace() async throws -> Block<[DiskSpace]> {
        await guarded("diskspace:block") {
            try await cached("diskspace", ttl: 300) {
                try await DashboardCards.diskSpace(radarr: try? registry.arr("radarr"), sonarr: try? registry.arr("sonarr"))
            }
        }
    }

    public func vpn() async throws -> Block<VpnStatus> {
        await guarded("vpn:block") {
            try await cached("vpn", ttl: 60) {
                try await DashboardCards.vpn(try registry.gluetun(), qbittorrent: try? registry.qbittorrent())
            }
        }
    }

    public func subtitles() async throws -> Block<Subtitles> {
        await guarded("subtitles:block") {
            try await cached("subtitles", ttl: 300) { try await DashboardCards.subtitles(try registry.bazarr()) }
        }
    }

    public func history() async throws -> [ArrApp: Block<[HistoryItem]>] {
        await dashboardArrBlocks("history") { app, client in
            DashboardPort.consolidateHistory(
                app: app, payload: try await DashboardPort.history(client, app: app, pageSize: 50)
            )
        }
    }

    /// Shared with the server's diagnosis under one key, so asking why
    /// something has not arrived does not ask Prowlarr three more times.
    public func indexerStats() async throws -> Block<IndexerStats> {
        await guarded("indexers:block") {
            try await cached("indexers:stats", ttl: 300) { try await DashboardCards.indexerStats(try registry.arr("prowlarr")) }
        }
    }

    /// The server samples the library every six hours while nobody looks;
    /// the device keeps no such record, so there is no history to chart.
    public func statsHistory(days: Int) async throws -> [StatsSample] {
        []
    }

    public func act(on requestID: Int, _ action: RequestAction) async throws {
        try await call {
            try await registry.overseerr().send("POST", "/request/\(requestID)/\(action.rawValue)")
            // the pending list and the arrs' queues both just changed
            cache.clear()
        }
    }

    public func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws {
        try await call {
            let bazarr = try registry.bazarr()
            switch kind {
            case .movie:
                try await bazarr.sendForm("PATCH", "/movies", [("action", "search-missing"), ("radarrid", String(id))])
            case .episode:
                guard let seriesID else { throw APIError.refused("episodes need a series_id") }
                try await bazarr.sendForm(
                    "PATCH", "/episodes",
                    [("action", "search-missing"), ("episodeid", String(id)), ("seriesid", String(seriesID))]
                )
            }
            // what the server did: the counts are re-read on the next poll
            forget("subtitles")
        }
    }

    /// Rescues a stuck import: the arr's manual-import candidates it has
    /// already placed with confidence, imported as they are.
    public func forceImport(app: ArrApp, id: Int) async throws {
        try await call {
            let client = try registry.arr(app.rawValue)
            let record = try await DashboardPort.queueRecord(client, app: app, id: id)
            guard let download = record["downloadId"].nonEmpty else {
                throw APIError.refused("queue item not found")
            }
            let candidates = try await client.get(
                "/manualimport", query: ["downloadId": download, "filterExistingFiles": "false"]
            )
            let files = candidates.array.compactMap { DashboardForceImport.file(app: app, candidate: $0, download: download) }
            guard !files.isEmpty else { throw APIError.refused("no importable files could be mapped automatically") }
            try await client.send(
                "POST", "/command", json: ["name": "ManualImport", "files": .array(files), "importMode": "auto"]
            )
        }
    }

    /// Removes a queue item from the download client, blocklists the release
    /// and goes straight looking for another.
    public func blocklistRetry(app: ArrApp, id: Int) async throws {
        try await call {
            let client = try registry.arr(app.rawValue)
            let record = try await DashboardPort.queueRecord(client, app: app, id: id)
            try await client.send("DELETE", "/queue/\(id)", query: ["removeFromClient": "true", "blocklist": "true"])
            if let search = Self.replacementSearch(app: app, record: record) {
                try await client.send("POST", "/command", json: search)
            }
        }
    }

    /// The command that hunts for a replacement of what a queue record was
    /// downloading, when the record says what that was.
    private static func replacementSearch(app: ArrApp, record: JSON) -> JSON? {
        switch app {
        case .radarr:
            return record["movieId"].nonZero.map { ["name": "MoviesSearch", "movieIds": [.init($0)]] }
        case .sonarr:
            if let episode = record["episodeId"].nonZero { return ["name": "EpisodeSearch", "episodeIds": [.init(episode)]] }
            return record["seriesId"].nonZero.map { ["name": "SeriesSearch", "seriesId": .init($0)] }
        case .readarr:
            return record["bookId"].nonZero.map { ["name": "BookSearch", "bookIds": [.init($0)]] }
        case .lidarr:
            return record["albumId"].nonZero.map { ["name": "AlbumSearch", "albumIds": [.init($0)]] }
        }
    }
}

// MARK: - Torrent summaries

extension DirectBackend {
    private func qbittorrentSummary() async throws -> TorrentSummary {
        let client = try registry.qbittorrent()
        async let torrents = TorrentCalls.qbittorrentTorrents(client)
        async let transfer = TorrentCalls.qbittorrentSpeeds(client)
        let (items, speeds) = try await (torrents, transfer)
        return DashboardCards.summary(
            TorrentRows.qbittorrent(items, resolve: TorrentRows.hostOnly),
            totals: averagedTotals(.qbittorrent, down: speeds.down, up: speeds.up)
        )
    }

    private func transmissionSummary() async throws -> TorrentSummary {
        let client = try registry.transmission()
        let items = try await TorrentCalls.transmissionTorrents(client)
        let speeds = try await TorrentCalls.transmissionSpeeds(client)
        return DashboardCards.summary(
            TorrentRows.transmission(items, resolve: TorrentRows.hostOnly),
            totals: averagedTotals(.transmission, down: speeds.down, up: speeds.up)
        )
    }

    /// The last minute's speeds averaged: an instant reading bounces about,
    /// and the card is polled every few seconds. The window lives in this
    /// backend's cache, so each profile keeps its own and it goes with it.
    private func averagedTotals(_ client: TorrentClient, down: Int, up: Int, now: Date = .now) -> (down: Int, up: Int) {
        let key = "torrents:speeds:\(client.rawValue)"
        let earlier: [TransferSample] = cache.stale(key, now: now)?.value ?? []
        let samples = earlier.filter { now.timeIntervalSince($0.at) <= Self.speedWindow }
            + [TransferSample(at: now, down: down, up: up)]
        cache.set(key, samples, now: now)
        return (samples.map(\.down).reduce(0, +) / samples.count, samples.map(\.up).reduce(0, +) / samples.count)
    }

    private static let speedWindow: TimeInterval = 60
}

private struct TransferSample: Sendable {
    let at: Date
    let down: Int
    let up: Int
}

// MARK: - Force import

/// The ManualImport command's files, ported from the server's importing.py:
/// a candidate goes in only when the arr placed it itself.
enum DashboardForceImport {
    static func file(app: ArrApp, candidate: JSON, download: String?) -> JSON? {
        guard candidate["quality"].truthy, let target = target(app: app, candidate: candidate) else { return nil }
        var fields: [String: JSON] = ["path": candidate["path"], "quality": candidate["quality"]]
        switch app {
        case .readarr:
            // Readarr's ManualImportFile has no languages or release group
            fields["indexerFlags"] = candidate["indexerFlags"].truthy ? candidate["indexerFlags"] : 0
        case .lidarr:
            // nor Lidarr's, which asks instead whether it may move the album to
            // the release the files fit better
            fields["indexerFlags"] = candidate["indexerFlags"].truthy ? candidate["indexerFlags"] : 0
            fields["disableReleaseSwitching"] = .bool(candidate["disableReleaseSwitching"].truthy)
        case .radarr, .sonarr:
            fields["languages"] = candidate.object["languages"] ?? []
            fields["releaseGroup"] = .string(candidate["releaseGroup"].nonEmpty ?? "")
        }
        // Ties the file to the tracked download. Without it "auto" means move,
        // and the torrent loses its files and stops seeding.
        if let download, !download.isEmpty { fields["downloadId"] = .string(download) }
        return .object(fields.merging(target) { _, target in target })
    }

    /// The arr's own match as payload ids, or nil when it could not place the
    /// file, stub match or not.
    static func target(app: ArrApp, candidate: JSON) -> [String: JSON]? {
        switch app {
        case .radarr:
            return candidate["movie"]["id"].nonZero.map { ["movieId": .init($0)] }
        case .readarr:
            guard let author = candidate["author"]["id"].nonZero, let book = candidate["book"]["id"].nonZero,
                  candidate["foreignEditionId"].truthy else { return nil }
            return ["authorId": .init(author), "bookId": .init(book), "foreignEditionId": candidate["foreignEditionId"]]
        case .lidarr:
            // a file goes on tracks of one release of an album: all four, or none
            let tracks = candidate["tracks"].array.compactMap { $0["id"].nonZero }
            guard let artist = candidate["artist"]["id"].nonZero, let album = candidate["album"]["id"].nonZero,
                  candidate["albumReleaseId"].truthy, !tracks.isEmpty else { return nil }
            return [
                "artistId": .init(artist), "albumId": .init(album),
                "albumReleaseId": candidate["albumReleaseId"], "trackIds": .init(tracks),
            ]
        case .sonarr:
            let episodes = candidate["episodes"].array.compactMap { $0["id"].nonZero }
            guard let series = candidate["series"]["id"].nonZero, !episodes.isEmpty else { return nil }
            return ["seriesId": .init(series), "episodeIds": .init(episodes)]
        }
    }
}
