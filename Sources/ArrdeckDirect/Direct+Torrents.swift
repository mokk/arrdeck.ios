import ArrdeckData
import Foundation

/// qBittorrent's and Transmission's torrents in the one shape the screens
/// read, ported from the server's torrents.py. Internal rather than private:
/// the dashboard's torrent summary maps the same rows.
enum TorrentRows {
    /// qBittorrent's states folded into the handful the filter offers. Its
    /// paused-after-finishing states read "completed", not "paused", so a
    /// finished torrent is not mistaken for one waiting on the user.
    static let qbittorrentStates: [String: String] = [
        "downloading": "downloading",
        "forcedDL": "downloading",
        "metaDL": "downloading",
        "stalledDL": "stalled",
        "uploading": "seeding",
        "forcedUP": "seeding",
        "stalledUP": "seeding",
        "pausedDL": "paused",
        "stoppedDL": "paused",
        "pausedUP": "completed",
        "stoppedUP": "completed",
        "queuedDL": "queued",
        "queuedUP": "queued",
        "checkingDL": "checking",
        "checkingUP": "checking",
        "checkingResumeData": "checking",
        "moving": "checking",
        "error": "error",
        "missingFiles": "error",
    ]

    /// Transmission's numeric status (rpc-spec.md): the three pending states
    /// are all "queued".
    static let transmissionStates: [Int: String] = [
        0: "paused",
        1: "queued",
        2: "checking",
        3: "queued",
        4: "downloading",
        5: "queued",
        6: "seeding",
    ]

    /// What `torrent-get` is asked for; Transmission sends nothing it is not
    /// asked for.
    static let transmissionFields: JSON = .array([
        "doneDate", "id", "hashString", "name", "status", "percentDone", "totalSize", "rateDownload",
        "rateUpload", "eta", "uploadRatio", "uploadedEver", "errorString", "downloadDir", "peersConnected",
        "addedDate", "trackers",
    ])

    /// qBittorrent's "no estimate": 100 days in seconds.
    static let qbittorrentNoETA = 8_640_000

    typealias Resolve = @Sendable (_ host: String?, _ hash: String) -> String?

    /// The announce host, without the "tracker." or "www." most trackers put
    /// in front of their name.
    static func trackerHost(_ url: String?) -> String? {
        guard let url, !url.isEmpty, var host = URL(string: url)?.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("tracker.") || host.hasPrefix("www."), let dot = host.firstIndex(of: ".") {
            host = String(host[host.index(after: dot)...])
        }
        return host
    }

    static func qbittorrent(_ items: JSON, resolve: Resolve) -> [Torrent] {
        items.array.map { t in
            let hash = t["hash"].string ?? ""
            let state = t["state"].string
            let eta = t["eta"].int
            let completed = t["completion_on"].int ?? 0
            return Torrent(
                added_on: t["added_on"].int,
                client: .qbittorrent,
                completed_on: completed > 0 ? completed : nil,
                dl_speed: t["dlspeed"].int ?? 0,
                eta: eta == qbittorrentNoETA ? nil : eta,
                id: hash,
                name: t["name"].string ?? "",
                progress: t["progress"].double ?? 0,
                ratio: t["ratio"].double,
                size: t["size"].int ?? 0,
                state: state.map { qbittorrentStates[$0] ?? $0 } ?? "unknown",
                // one comma-separated string
                tags: (t["tags"].string ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                tracker: resolve(trackerHost(t["tracker"].string), hash.uppercased()),
                ul_speed: t["upspeed"].int ?? 0,
                uploaded: t["uploaded"].int ?? 0
            )
        }
    }

    static func transmission(_ items: JSON, resolve: Resolve) -> [Torrent] {
        items.array.map { t in
            let error = t["errorString"].nonEmpty
            let eta = t["eta"].int ?? -1
            let done = t["doneDate"].int ?? 0
            return Torrent(
                added_on: t["addedDate"].int,
                client: .transmission,
                completed_on: done > 0 ? done : nil,
                dl_speed: t["rateDownload"].int ?? 0,
                error: error,
                eta: eta > 0 ? eta : nil,
                id: t["id"].int.map(String.init) ?? "",
                name: t["name"].string ?? "",
                progress: t["percentDone"].double ?? 0,
                ratio: t["uploadRatio"].double,
                size: t["totalSize"].int ?? 0,
                state: error != nil ? "error" : t["status"].int.flatMap { transmissionStates[$0] } ?? "unknown",
                tags: [],
                tracker: resolve(
                    trackerHost(t["trackers"][0]["announce"].string), (t["hashString"].string ?? "").uppercased()
                ),
                ul_speed: t["rateUpload"].int ?? 0,
                uploaded: t["uploadedEver"].int ?? 0
            )
        }
    }

    /// One client's torrents filtered, sorted and capped, as the server did
    /// it. Each client is capped on its own and the screen merges the two,
    /// which still finds the overall top N: anything in it is in its own
    /// client's top N too.
    static func select(_ rows: [Torrent], _ query: TorrentQuery, download: Int, upload: Int) -> TorrentGroup {
        // every state there is, before filtering, so the filter keeps its options
        let states = Set(rows.map(\.state).filter { !$0.isEmpty }).sorted()
        let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state = query.state ?? ""
        let matched = rows.filter { row in
            (state.isEmpty || state == "all" || row.state == state)
                && (needle.isEmpty || row.name.lowercased().contains(needle))
        }
        let sorted = TorrentSorting.sort(matched, by: query.sort, descending: query.descending)
        return TorrentGroup(
            states: states,
            // a bad limit still shows something rather than an empty screen
            torrents: Array(sorted.prefix(max(1, query.limit))),
            total: matched.count,
            totals: .init(dl_speed: download, ul_speed: upload)
        )
    }
}

/// Which indexer a torrent came from, for the list's tracker column: an
/// announce host means little, "TorrentLeech" does. Exact where an arr's grab
/// history names the hash, by the tracker's domain otherwise.
struct TrackerNames: Sendable {
    /// Registered domain → Prowlarr indexer, from each indexer's site URLs.
    let byDomain: [String: String]
    /// Torrent hash (upper case) → indexer, from Radarr's and Sonarr's grabs.
    let byHash: [String: String]
    /// Domains learned from hash matches, kept for torrents whose grab has
    /// since dropped out of the history.
    let learned: Locked<[String: String]>

    static let learnedKey = "tracker:learned_domains"

    static func registeredDomain(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).suffix(2).joined(separator: ".")
    }

    func resolve(host: String?, hash: String) -> String? {
        if let name = byHash[hash] {
            if let host { learned.withLock { $0[Self.registeredDomain(host)] = name } }
            return name
        }
        guard let host else { return nil }
        let domain = Self.registeredDomain(host)
        return byDomain[domain] ?? learned.withLock { $0[domain] } ?? host
    }
}

extension TrackerNames {
    /// The names are cosmetic, so nothing here ever fails the list: a
    /// missing Prowlarr or arr simply leaves the hosts as they are.
    static func load(_ backend: DirectBackend) async -> TrackerNames {
        async let domains = indexerDomains(backend)
        async let hashes = grabbedHashes(backend)
        let learned: [String: String] = backend.cache.stale(learnedKey)?.value ?? [:]
        return TrackerNames(byDomain: await domains, byHash: await hashes, learned: Locked(learned))
    }

    private static func indexerDomains(_ backend: DirectBackend) async -> [String: String] {
        (try? await backend.cached("tracker:indexer_map", ttl: 300) {
            var mapping: [String: String] = [:]
            for indexer in try await backend.registry.arr("prowlarr").get("/indexer").array {
                guard let name = indexer["name"].string else { continue }
                // its own site and the mirrors it has moved from
                for url in indexer["indexerUrls"].array + indexer["legacyUrls"].array {
                    if let host = url.string.flatMap({ URL(string: $0)?.host()?.lowercased() }), !host.isEmpty {
                        mapping[TrackerNames.registeredDomain(host)] = name
                    }
                }
            }
            return mapping
        }) ?? [:]
    }

    private static func grabbedHashes(_ backend: DirectBackend) async -> [String: String] {
        (try? await backend.cached("tracker:history_map", ttl: 300) {
            var mapping: [String: String] = [:]
            for app in ["radarr", "sonarr"] {
                // one arr down leaves the other's grabs
                guard let history = try? await backend.registry.arr(app).get("/history", query: [
                    "pageSize": "500", "page": "1", "sortKey": "date", "sortDirection": "descending",
                ]) else { continue }
                for record in history["records"].array {
                    let download = (record["downloadId"].string ?? "").uppercased()
                    if !download.isEmpty, let indexer = record["data"]["indexer"].string, !indexer.isEmpty {
                        mapping[download] = indexer.hasSuffix(" (Prowlarr)")
                            ? String(indexer.dropLast(" (Prowlarr)".count)) : indexer
                    }
                }
            }
            return mapping
        }) ?? [:]
    }
}

/// The torrent clients' write calls, shared by the Downloads screen's actions
/// and the detail sheet's.
enum TorrentCalls {
    /// qBittorrent's per-torrent actions all take their hashes joined by "|".
    static func qbittorrent(
        _ qbit: QbittorrentClient, _ action: String, _ hashes: [String], _ extra: [String: String] = [:]
    ) async throws {
        try await qbit.post("/api/v2/torrents/\(action)", form: extra.merging(["hashes": hashes.joined(separator: "|")]) { _, new in new })
    }

    /// Transmission addresses torrents by its own small integers.
    static func transmissionIDs(_ ids: [String]) throws -> JSON {
        try JSON(ids.map { id in
            guard let number = Int(id) else { throw APIError.refused("transmission ids must be integers") }
            return number
        })
    }

    /// qBittorrent's alternative speed limits. /transfer/info stopped
    /// reporting them in 5.x; speedLimitsMode answers a plain "0" or "1".
    static func qbittorrentThrottled(_ qbit: QbittorrentClient) async throws -> Bool {
        try await qbit.request("GET", "/api/v2/transfer/speedLimitsMode").text
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
