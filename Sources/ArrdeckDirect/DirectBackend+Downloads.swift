import ArrdeckData
import Foundation

/// The Downloads screen, from the server's torrents.py, torrentactions.py and
/// arrqueue.py. The queue and its import and blocklist actions are the
/// dashboard's.
extension DirectBackend: DownloadsAPI {
    /// Both clients' lists, each filtered and capped on its own. The transfer
    /// totals are the clients' speeds right now: the server averaged them over
    /// the last minute of its own polling, which the app has no minute of.
    public func torrents(_ query: TorrentQuery) async throws -> [TorrentClient: Block<TorrentGroup>] {
        let names = await TrackerNames.load(self)
        let resolve: TorrentRows.Resolve = { names.resolve(host: $0, hash: $1) }
        async let qbittorrent = guarded("torrents:qbit") {
            let qbit = try registry.qbittorrent()
            async let items = TorrentCalls.qbittorrentTorrents(qbit)
            async let speeds = TorrentCalls.qbittorrentSpeeds(qbit)
            let totals = try await speeds
            return TorrentRows.select(
                TorrentRows.qbittorrent(try await items, resolve: resolve), query, download: totals.down, upload: totals.up
            )
        }
        async let transmission = guarded("torrents:tm") {
            let tm = try registry.transmission()
            async let items = TorrentCalls.transmissionTorrents(tm)
            async let speeds = TorrentCalls.transmissionSpeeds(tm)
            let totals = try await speeds
            return TorrentRows.select(
                TorrentRows.transmission(try await items, resolve: resolve), query, download: totals.down, upload: totals.up
            )
        }
        let groups: [TorrentClient: Block<TorrentGroup>] = await [.qbittorrent: qbittorrent, .transmission: transmission]
        cache.set(TrackerNames.learnedKey, names.learned.current)
        return groups
    }

    /// Whether each client is throttled. A client that is not set up or does
    /// not answer reads as not throttled, so the other's toggle still shows.
    public func speedLimit() async throws -> [TorrentClient: Bool] {
        async let qbittorrent = try? TorrentCalls.qbittorrentThrottled(registry.qbittorrent())
        async let transmission = try? registry.transmission().rpc("session-get")["alt-speed-enabled"].bool
        return await [.qbittorrent: qbittorrent ?? false, .transmission: transmission ?? false]
    }

    public func setSpeedLimit(_ client: TorrentClient, enabled: Bool) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                // qBittorrent only toggles, so a "turn on" sent twice would
                // turn it off again
                let qbit = try registry.qbittorrent()
                if try await TorrentCalls.qbittorrentThrottled(qbit) != enabled {
                    try await qbit.post("/api/v2/transfer/toggleSpeedLimitsMode")
                }
            case .transmission:
                try await registry.transmission().rpc("session-set", ["alt-speed-enabled": .bool(enabled)])
            }
        }
    }

    public func pause(_ client: TorrentClient, ids: [String]) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                try await qbittorrentRenamed(ids, current: "stop", old: "pause")
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs(ids)
                try await registry.transmission().rpc("torrent-stop", ["ids": ids])
            }
        }
    }

    public func resume(_ client: TorrentClient, ids: [String]) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                try await qbittorrentRenamed(ids, current: "start", old: "resume")
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs(ids)
                try await registry.transmission().rpc("torrent-start", ["ids": ids])
            }
        }
    }

    public func delete(_ client: TorrentClient, ids: [String], deleteData: Bool) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                try await TorrentCalls.qbittorrent(
                    registry.qbittorrent(), "delete", ids, ["deleteFiles": deleteData ? "true" : "false"]
                )
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs(ids)
                try await registry.transmission().rpc("torrent-remove", ["ids": ids, "delete-local-data": .bool(deleteData)])
            }
        }
    }

    public func recheck(_ client: TorrentClient, ids: [String]) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                try await TorrentCalls.qbittorrent(registry.qbittorrent(), "recheck", ids)
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs(ids)
                try await registry.transmission().rpc("torrent-verify", ["ids": ids])
            }
        }
    }

    public func details(_ client: TorrentClient, id: String) async throws -> TorrentDetails {
        try await call {
            switch client {
            case .qbittorrent: try await qbittorrentDetails(id)
            case .transmission: try await transmissionDetails(id)
            }
        }
    }

    public func removeFromQueue(app: ArrApp, id: Int) async throws {
        try await call {
            _ = try await registry.arr(app.rawValue).send(
                "DELETE", "/queue/\(id)", query: ["removeFromClient": "true", "blocklist": "false"]
            )
        }
    }

    /// qBittorrent 5.x renamed pause and resume to stop and start; an older
    /// one answers the new names with a 404. Only a refusal falls back — a
    /// client that is down is down under either name.
    private func qbittorrentRenamed(_ hashes: [String], current: String, old: String) async throws {
        let qbit = try registry.qbittorrent()
        do {
            try await TorrentCalls.qbittorrent(qbit, current, hashes)
        } catch is ServiceRefused {
            try await TorrentCalls.qbittorrent(qbit, old, hashes)
        }
    }

    private func qbittorrentDetails(_ hash: String) async throws -> TorrentDetails {
        let qbit = try registry.qbittorrent()
        async let files = qbit.get("/api/v2/torrents/files", query: ["hash": hash])
        async let info = qbit.get("/api/v2/torrents/info", query: ["hashes": hash])
        async let categories = qbit.get("/api/v2/torrents/categories")
        async let trackers = qbit.get("/api/v2/torrents/trackers", query: ["hash": hash])
        let torrent = try await info[0]
        return TorrentDetails(
            categories: try await categories.object.keys.sorted(),
            category: torrent["category"].nonEmpty,
            dl_limit_kib: max(torrent["dl_limit"].int ?? 0, 0) / 1024,
            files: try await files.array.enumerated().map { index, file in
                TorrentFile(
                    index: file["index"].int ?? index,
                    name: file["name"].string ?? "",
                    progress: file["progress"].double ?? 0,
                    size: file["size"].int ?? 0,
                    wanted: (file["priority"].int ?? 1) > 0
                )
            },
            // "** [DHT] **" and its kind are not trackers; status 4 is "not working"
            trackers: try await trackers.array.compactMap { tracker in
                let url = tracker["url"].string ?? ""
                guard !url.hasPrefix("**") else { return nil }
                return Tracker(
                    host: url,
                    message: tracker["msg"].nonEmpty,
                    ok: tracker["status"].int != 4
                )
            },
            ul_limit_kib: max(torrent["up_limit"].int ?? 0, 0) / 1024
        )
    }

    private func transmissionDetails(_ id: String) async throws -> TorrentDetails {
        let ids = try TorrentCalls.transmissionIDs([id])
        let result = try await registry.transmission().rpc("torrent-get", [
            "ids": ids,
            "fields": ["files", "fileStats", "downloadLimit", "downloadLimited", "uploadLimit", "uploadLimited", "trackerStats"],
        ])
        let detail = result["torrents"][0]
        let stats = detail["fileStats"]
        return TorrentDetails(
            categories: [],
            dl_limit_kib: detail["downloadLimited"].bool == true ? detail["downloadLimit"].int ?? 0 : 0,
            files: detail["files"].array.enumerated().map { index, file in
                let length = file["length"].int ?? 0
                return TorrentFile(
                    index: index,
                    name: file["name"].string ?? "",
                    progress: length > 0 ? Double(file["bytesCompleted"].int ?? 0) / Double(length) : 0,
                    size: length,
                    wanted: stats[index]["wanted"].bool ?? true
                )
            },
            trackers: detail["trackerStats"].array.map { tracker in
                let succeeded = tracker["lastAnnounceSucceeded"].bool ?? true
                return Tracker(
                    host: tracker["host"].nonEmpty ?? tracker["announce"].string ?? "",
                    message: succeeded ? nil : tracker["lastAnnounceResult"].string,
                    ok: succeeded
                )
            },
            ul_limit_kib: detail["uploadLimited"].bool == true ? detail["uploadLimit"].int ?? 0 : 0
        )
    }
}
