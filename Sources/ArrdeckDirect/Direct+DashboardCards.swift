import ArrdeckData
import Foundation

/// The dashboard's cards, each built from its service's answers the way the
/// server's handler built it: plex.py, requests.py, torrents.py, system.py,
/// subtitles.py and dashboard.py. Pure where it can be, so the mapping is
/// tested without a network.
enum DashboardCards {
    // MARK: - Plex

    static func playSessions(_ plex: KeyedClient) async throws -> [PlaySession] {
        async let identity = Plex.machine(plex)
        let items = try await plex.get("/status/sessions")["MediaContainer"]["Metadata"].array
        let machine = await identity
        return items.map { playSession(machine: machine, item: $0) }
    }

    static func playSession(machine: String, item: JSON) -> PlaySession {
        let kind = item["type"].string ?? ""
        let title = kind == "episode" ? item["grandparentTitle"].string : item["title"].string
        var subtitle: String?
        if kind == "episode" {
            subtitle = item["title"].string ?? ""
            if let season = item["parentIndex"].int, let number = item["index"].int {
                subtitle = DashboardPort.episodeCode(season, number) + " – " + (subtitle ?? "")
                while let last = subtitle?.last, last == " " || last == "–" { subtitle?.removeLast() }
            }
        }
        let duration = item["duration"].double ?? 0
        let ratingKey = Plex.key(item["ratingKey"])
        return PlaySession(
            kind: kind,
            player: item["Player"]["title"].string ?? "",
            progress: duration > 0 ? (item["viewOffset"].double ?? 0) / duration : 0,
            state: item["Player"]["state"].string ?? "",
            subtitle: subtitle,
            title: title ?? "",
            // a transcode session means the server is doing real work for this play
            transcoding: item["TranscodeSession"].truthy,
            url: !machine.isEmpty && ratingKey.map { !$0.isEmpty } == true
                ? Plex.detailsBase(machine: machine) + ratingKey!
                : nil,
            user: item["User"]["title"].string ?? ""
        )
    }

    // MARK: - Overseerr

    /// One page of Overseerr's requests in one state, by when they were added.
    static func requests(_ overseerr: KeyedClient, filter: String, take: Int) async throws -> JSON {
        try await overseerr.get("/request", query: ["filter": filter, "take": String(take), "sort": "added"])
    }

    /// A request's "movie" or "tv", whichever field Overseerr put it in.
    static func requestKind(_ request: JSON) -> String {
        request["type"].nonEmpty ?? request["media"]["mediaType"].nonEmpty ?? "movie"
    }

    static func pendingRequests(_ overseerr: KeyedClient) async throws -> [MediaRequest] {
        let payload = try await requests(overseerr, filter: "pending", take: 20)
        let results = payload["results"].array
        return await withTaskGroup(of: (Int, MediaRequest).self) { group in
            for (index, request) in results.enumerated() {
                group.addTask { (index, await describe(request, overseerr: overseerr)) }
            }
            var described: [(Int, MediaRequest)] = []
            for await row in group { described.append(row) }
            return described.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Overseerr's request list carries only a TMDB id, so the title comes
    /// from a second lookup, which Overseerr answers from its own cache.
    static func describe(_ request: JSON, overseerr: KeyedClient) async -> MediaRequest {
        let media = request["media"]
        let kind = requestKind(request)
        var title = "", year: String?, poster: String?
        if let tmdb = media["tmdbId"].nonZero {
            // a missing title must not drop the request
            let details = (try? await overseerr.get(kind == "movie" ? "/movie/\(tmdb)" : "/tv/\(tmdb)")) ?? [:]
            title = details["title"].nonEmpty ?? details["name"].nonEmpty ?? ""
            let date = details["releaseDate"].nonEmpty ?? details["firstAirDate"].nonEmpty
            year = date.map { String($0.prefix(4)) }
            poster = Artwork.tmdbPoster(details["posterPath"].string)
        }
        return MediaRequest(
            created_at: request["createdAt"].string,
            id: request["id"].int ?? 0,
            poster: poster,
            requested_by: request["requestedBy"]["displayName"].nonEmpty ?? "",
            seasons: request["seasons"].array.compactMap { $0["seasonNumber"].nonZero },
            status: request["status"].int ?? 0,
            title: title,
            _type: kind,
            year: year
        )
    }

    // MARK: - Torrent clients

    /// Totals and the five busiest: about 1% of the full list, for a card
    /// polled every few seconds.
    static func summary(_ torrents: [Torrent], totals: (down: Int, up: Int)) -> TorrentSummary {
        let active = DashboardPort.stableSorted(
            torrents.filter { $0.state == "downloading" || $0.dl_speed > 0 || $0.ul_speed > 0 }
        ) { $0.dl_speed + $0.ul_speed > $1.dl_speed + $1.ul_speed }
        return TorrentSummary(
            active: Array(active.prefix(5)), active_count: active.count, count: torrents.count,
            totals: .init(dl_speed: totals.down, ul_speed: totals.up)
        )
    }

    // MARK: - Disks

    /// Free space where the library lives, from the root folders: inside
    /// Docker an arr's /diskspace reports its own container's disk, not the
    /// mounted media volume. A mount that is exactly a root folder still
    /// supplies the total, which root folders do not carry.
    static func diskSpace(radarr: KeyedClient?, sonarr: KeyedClient?) async throws -> [DiskSpace] {
        async let radarrRoots = radarr?.get("/rootfolder")
        async let sonarrRoots = sonarr?.get("/rootfolder")
        async let radarrMounts = radarr?.get("/diskspace")
        async let sonarrMounts = sonarr?.get("/diskspace")
        let roots = [("radarr", try? await radarrRoots), ("sonarr", try? await sonarrRoots)]
        var totals: [String: Int] = [:]
        for mounts in [try? await radarrMounts, try? await sonarrMounts] {
            for entry in mounts?.array ?? [] {
                if let path = entry["path"].nonEmpty {
                    totals[path] = entry["totalSpace"].whole ?? 0
                }
            }
        }
        var merged: [String: DiskSpace] = [:]
        for (app, folders) in roots {
            for entry in folders?.array ?? [] {
                guard let path = entry["path"].nonEmpty, merged[path] == nil else { continue }
                merged[path] = DiskSpace(
                    free_bytes: entry["freeSpace"].whole ?? 0, label: app, path: path,
                    total_bytes: totals[path] ?? 0
                )
            }
        }
        guard !merged.isEmpty else { throw ServiceUnavailable("radarr", "no root folders") }
        return merged.values.sorted { $0.path < $1.path }
    }

    // MARK: - VPN

    /// The tunnel, the exit address, and whether qBittorrent listens on the
    /// port the VPN forwarded: a mismatch is silently unconnectable. Only the
    /// tunnel's own state is required.
    static func vpn(_ gluetun: KeyedClient, qbittorrent: QbittorrentClient?) async throws -> VpnStatus {
        async let status = gluetun.get("/v1/vpn/status")
        async let ip = gluetun.get("/v1/publicip/ip")
        async let forward = gluetun.get("/v1/portforward")
        async let prefs = qbittorrent?.get("/api/v2/app/preferences")
        let tunnel = try await status
        let address = (try? await ip) ?? [:]
        let forwarded = (try? await forward)?["port"].nonZero
        let listening = (try? await prefs)?["listen_port"].nonZero
        return VpnStatus(
            city: address["city"].string,
            client_port: listening,
            country: address["country"].string,
            forwarded_port: forwarded,
            port_matches: forwarded.flatMap { forwarded in listening.map { $0 == forwarded } },
            public_ip: address["public_ip"].string ?? "",
            status: tunnel["status"].string ?? ""
        )
    }

    // MARK: - Health

    /// Radarr's and Sonarr's own checks, an enabled download client, and
    /// unpackerr's failures through Prometheus. Prowlarr's checks are on the
    /// indexer card already. Every part is optional: what cannot be asked
    /// simply adds nothing.
    static func health(radarr: KeyedClient?, sonarr: KeyedClient?, prometheus: KeyedClient?) async -> [HealthWarning] {
        async let radarrChecks = radarr?.get("/health")
        async let sonarrChecks = sonarr?.get("/health")
        async let unpackerr = unpackerrWarnings(prometheus)
        async let clients = downloadClientWarnings(radarr: radarr, sonarr: sonarr)
        var warnings: [HealthWarning] = []
        for (app, checks) in [("radarr", try? await radarrChecks), ("sonarr", try? await sonarrChecks)] {
            for entry in checks?.array ?? [] {
                // "a newer version exists" is permanent and not actionable from
                // here; it would keep the card always on, and an always-on
                // warning card stops being read
                if entry["source"].string == "UpdateCheck" { continue }
                warnings.append(HealthWarning(
                    app: app, level: entry["type"].nonEmpty ?? "warning",
                    message: entry["message"].nonEmpty ?? "", source: entry["source"].string,
                    wiki_url: entry["wikiUrl"].string
                ))
            }
        }
        warnings += await unpackerr
        warnings += await clients
        // errors first, so the worst thing is the first thing read
        return DashboardPort.stableSorted(warnings) { a, b in
            ((a.level != "error") ? 1 : 0, a.app) < ((b.level != "error") ? 1 : 0, b.app)
        }
    }

    /// A disabled or absent download client is a silent failure: the arr
    /// never grabs anything and says nothing about it.
    static func downloadClientWarnings(radarr: KeyedClient?, sonarr: KeyedClient?) async -> [HealthWarning] {
        async let radarrClients = radarr?.get("/downloadclient")
        async let sonarrClients = sonarr?.get("/downloadclient")
        var warnings: [HealthWarning] = []
        for (app, result) in [("radarr", try? await radarrClients), ("sonarr", try? await sonarrClients)] {
            guard let clients = result else { continue }
            if !clients.array.contains(where: { $0["enable"].truthy }) {
                warnings.append(HealthWarning(
                    app: app, level: "error", message: "no download client is enabled", source: "DownloadClient"
                ))
            }
        }
        return warnings
    }

    /// Counters are lifetime totals: a blip during a restart would warn
    /// forever, so only a failure inside this window counts.
    static let failureWindow = "1h"
    /// Docker's route back to the host stalls briefly under load, so
    /// unpackerr logs the odd queue-fetch timeout that clears by itself.
    /// Three in the window is a pattern; one is weather.
    static let queueFetchThreshold = 3.0

    /// Extraction problems: a download that completes and never imports is
    /// usually unpackerr failing quietly, which nothing else surfaces.
    static func unpackerrWarnings(_ prometheus: KeyedClient?) async -> [HealthWarning] {
        guard let prometheus else { return [] }
        async let gauges = scalars(prometheus, "unpackerr_gauges")
        async let counters = scalars(prometheus, "increase(unpackerr_counters[\(failureWindow)])")
        // keyed by "app", not "name" like the gauge families
        async let fetchErrors = scalars(
            prometheus, "increase(unpackerr_app_queue_fetch_errors_total[\(failureWindow)])", label: "app"
        )
        var warnings: [HealthWarning] = []
        if let failed = (try? await gauges)?["failed"], failed > 0 {
            warnings.append(HealthWarning(
                app: "unpackerr", level: "error", message: "\(Int(failed)) extraction(s) failed", source: "Unpackerr"
            ))
        }
        if let counters = try? await counters {
            for key in ["cmd_fail", "hook_fail"] {
                guard let count = counters[key], count >= 1 else { continue }
                warnings.append(HealthWarning(
                    app: "unpackerr", level: "warning",
                    message: "\(Int(count)) \(key.replacingOccurrences(of: "_", with: " ")) in the last hour",
                    source: "Unpackerr"
                ))
            }
        }
        if let fetchErrors = try? await fetchErrors {
            for (app, count) in fetchErrors.sorted(by: { $0.key < $1.key }) where count >= queueFetchThreshold {
                warnings.append(HealthWarning(
                    app: "unpackerr", level: "warning",
                    message: "cannot read \(app.isEmpty ? "an arr" : app)'s queue (\(Int(count)) errors in the last hour)",
                    source: "Unpackerr"
                ))
            }
        }
        return warnings
    }

    /// An instant vector as {label value: number}, for the families unpackerr
    /// publishes as one metric with a name label.
    static func scalars(_ prometheus: KeyedClient, _ expression: String, label: String = "name") async throws
        -> [String: Double]
    {
        let payload = try await prometheus.get("/api/v1/query", query: ["query": expression])
        guard payload["status"].string == "success" else {
            throw ServiceUnavailable("prometheus", payload["error"].string ?? "query failed")
        }
        var out: [String: Double] = [:]
        for row in payload["data"]["result"].array {
            let value = row["value"][1]
            guard let number = value.double ?? value.string.flatMap(Double.init) else { continue }
            out[row["metric"][label].string ?? ""] = number
        }
        return out
    }

    // MARK: - Bazarr

    /// What Bazarr still misses. The counts come from its badges, so they stay
    /// right though the list is capped.
    static func subtitles(_ bazarr: KeyedClient) async throws -> Subtitles {
        async let badges = bazarr.get("/badges")
        async let episodes = wanted(bazarr, .episode, start: 0, length: 20)
        async let movies = wanted(bazarr, .movie, start: 0, length: 20)
        let (counts, wantedEpisodes, wantedMovies) = try await (badges, episodes, movies)
        return Subtitles(
            episodes: counts["episodes"].whole ?? 0,
            items: wantedMovies["data"].array.map(wantedMovie) + wantedEpisodes["data"].array.map(wantedEpisode),
            movies: counts["movies"].whole ?? 0,
            // throttled providers, not configured ones: zero is the healthy answer
            throttled_providers: counts["providers"].whole ?? 0
        )
    }

    /// One page of what Bazarr still misses for films or for episodes.
    static func wanted(_ bazarr: KeyedClient, _ kind: SubtitleKind, start: Int, length: Int) async throws -> JSON {
        try await bazarr.get(
            kind == .movie ? "/movies/wanted" : "/episodes/wanted", query: ["start": "\(start)", "length": "\(length)"]
        )
    }

    static func missing(_ row: JSON) -> [String] {
        row["missing_subtitles"].array.map { $0["name"].string ?? "" }
    }

    static func wantedMovie(_ movie: JSON) -> SubtitleItem {
        SubtitleItem(id: movie["radarrId"].int ?? 0, kind: "movie", missing: missing(movie),
                     title: movie["title"].string ?? "")
    }

    static func wantedEpisode(_ episode: JSON) -> SubtitleItem {
        let number = episode["episode_number"].string ?? episode["episode_number"].int.map(String.init) ?? ""
        let subtitle = "\(number) \(episode["episodeTitle"].string ?? "")".trimmingCharacters(in: .whitespaces)
        return SubtitleItem(
            id: episode["sonarrEpisodeId"].int ?? 0, kind: "episode", missing: missing(episode),
            series_id: episode["sonarrSeriesId"].int, subtitle: subtitle, title: episode["seriesTitle"].string ?? ""
        )
    }

    // MARK: - Prowlarr

    static func indexerStats(_ prowlarr: KeyedClient) async throws -> IndexerStats {
        async let indexers = prowlarr.get("/indexer")
        async let stats = prowlarr.get("/indexerstats")
        async let health = prowlarr.get("/health")
        let (all, numbers, checks) = try await (indexers, stats, health)
        return IndexerStats(
            enabled: all.array.filter { $0["enable"].truthy }.count,
            health: checks.array.map {
                .init(message: $0["message"].string, source: $0["source"].string, _type: $0["type"].string)
            },
            stats: numbers["indexers"].array.map {
                .init(
                    avg_response_ms: $0["averageResponseTime"].whole ?? 0,
                    grabs: $0["numberOfGrabs"].whole ?? 0,
                    name: $0["indexerName"].string,
                    queries: $0["numberOfQueries"].whole ?? 0
                )
            },
            total: all.array.count
        )
    }

    // MARK: - Recently added

    /// Recently imported titles across the arrs, newest first, one entry per
    /// title. An arr that is down leaves its titles out rather than the strip.
    static func recent(_ registry: Registry) async -> [RecentItem] {
        async let movies = recentMovies(registry)
        async let shows = recentEpisodes(registry)
        async let books = registry.isConfigured("readarr") ? recentBooks(registry) : []
        async let albums = registry.isConfigured("lidarr") ? recentAlbums(registry) : []
        let all = await movies + shows + books + albums
        var seen: Set<String> = []
        return DashboardPort.stableSorted(all) { $0.date > $1.date }
            .filter { seen.insert("\($0.app)/\($0.library_id.map(String.init) ?? "")").inserted }
            .prefix(12).map { $0 }
    }

    private static func recentMovies(_ registry: Registry) async -> [RecentItem] {
        guard let radarr = try? registry.arr("radarr"),
              let library = try? await radarr.get("/movie"),
              let history = try? await DashboardPort.history(radarr, app: .radarr, pageSize: 40)
        else { return [] }
        let movies = library.array.byID
        return history["records"].array.compactMap { record in
            guard record["eventType"].string == "downloadFolderImported",
                  let id = record["movieId"].int, let movie = movies[id] else { return nil }
            return RecentItem(
                app: "radarr", date: record["date"].string ?? "", library_id: id,
                poster: Artwork.poster(movie["images"]),
                subtitle: movie["year"].nonZero.map(String.init),
                title: movie["title"].string ?? ""
            )
        }
    }

    private static func recentEpisodes(_ registry: Registry) async -> [RecentItem] {
        guard let sonarr = try? registry.arr("sonarr"),
              let library = try? await sonarr.get("/series"),
              let history = try? await DashboardPort.history(sonarr, app: .sonarr, pageSize: 40)
        else { return [] }
        let series = library.array.byID
        return history["records"].array.compactMap { record in
            guard record["eventType"].string == "downloadFolderImported",
                  let id = record["seriesId"].int, let show = series[id] else { return nil }
            return RecentItem(
                app: "sonarr", date: record["date"].string ?? "", library_id: id,
                poster: Artwork.poster(show["images"]),
                subtitle: episodeCode(record["sourceTitle"].string ?? ""),
                title: show["title"].string ?? ""
            )
        }
    }

    /// "S01E02" out of a release name, however the release spelled it.
    static func episodeCode(_ release: String) -> String? {
        guard let match = release.firstMatch(of: /[Ss](\d+)[Ee](\d+)/),
              let season = Int(match.1), let episode = Int(match.2) else { return nil }
        return DashboardPort.episodeCode(season, episode)
    }

    private static func recentBooks(_ registry: Registry) async -> [RecentItem] {
        guard let readarr = try? registry.arr("readarr"),
              let library = try? await readarr.get("/book"),
              let history = try? await DashboardPort.history(readarr, app: .readarr, pageSize: 40)
        else { return [] }
        let books = library.array.byID
        return history["records"].array.compactMap { record in
            guard record["eventType"].string == "bookFileImported",
                  let id = record["bookId"].int, let book = books[id] else { return nil }
            // "Surname, Given Title": the author's surname is enough beside a cover
            let author = (book["authorTitle"].string ?? "")
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let surname = String(author.reversed().drop { $0 == "," }.reversed())
            return RecentItem(
                app: "readarr", date: record["date"].string ?? "", library_id: id,
                poster: Artwork.bookCover(book["images"]), subtitle: surname.isEmpty ? nil : surname,
                title: book["title"].string ?? ""
            )
        }
    }

    /// A record per imported track, with its album and artist attached: the
    /// album is the title, and the dedupe in `recent` makes it one entry.
    private static func recentAlbums(_ registry: Registry) async -> [RecentItem] {
        guard let lidarr = try? registry.arr("lidarr"),
              let history = try? await DashboardPort.history(lidarr, app: .lidarr, pageSize: 60)
        else { return [] }
        return history["records"].array.compactMap { record in
            let album = record["album"]
            guard record["eventType"].string == "trackFileImported", let id = album["id"].nonZero
            else { return nil }
            return RecentItem(
                app: "lidarr", date: record["date"].string ?? "", library_id: id,
                poster: Artwork.musicCover(album["images"]),
                subtitle: record["artist"]["artistName"].nonEmpty,
                title: album["title"].string ?? ""
            )
        }
    }
}
