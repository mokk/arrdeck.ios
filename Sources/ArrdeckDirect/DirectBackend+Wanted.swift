import ArrdeckData
import Foundation

/// Missing and cutoff-unmet titles, searching for them, and "why hasn't this
/// arrived yet", ported from the server's wanted.py and diagnose.py.
extension DirectBackend: WantedAPI {
    private static let wantedPageSize = 30

    public func wanted(_ app: ArrApp, kind: WantedKind, page: Int) async throws -> WantedPage {
        try await call {
            let arr = try registry.arr(app.rawValue)
            // each arr sorts its list by its own idea of a release date
            var query: [String: String?] = [
                "page": "\(page)", "pageSize": "\(Self.wantedPageSize)", "sortDirection": "descending",
                "monitored": "true",
            ]
            switch app {
            case .radarr: query["sortKey"] = "movieMetadata.year"
            case .sonarr: (query["sortKey"], query["includeSeries"]) = ("airDateUtc", "true")
            case .readarr: (query["sortKey"], query["includeAuthor"]) = ("releaseDate", "true")
            case .lidarr: (query["sortKey"], query["includeArtist"]) = ("albums.releaseDate", "true")
            }
            let payload = try await arr.get("/wanted/\(kind.rawValue)", query: query)
            let items = payload["records"].array.map { Self.wantedItem(app, $0) }
            let total = payload["totalRecords"].int ?? 0
            return WantedPage(has_more: page * Self.wantedPageSize < total, items: items, total: total)
        }
    }

    /// One row: Radarr's movie, Sonarr's episode (under its series), Readarr's
    /// book, Lidarr's album.
    fileprivate static func wantedItem(_ app: ArrApp, _ record: JSON) -> WantedItem {
        let id = record["id"].int ?? 0
        let (library, title, subtitle, date, poster): (Int, String, String?, String?, String?) = switch app {
        case .radarr:
            (id, record["title"].string ?? "", record["year"].int.flatMap { $0 == 0 ? nil : String($0) },
             record["digitalRelease"].string ?? record["physicalRelease"].string ?? record["inCinemas"].string,
             Artwork.poster(record["images"]))
        case .sonarr:
            (record["seriesId"].int ?? 0, record["series"]["title"].string ?? "",
             String(format: "S%02dE%02d ", record["seasonNumber"].int ?? 0, record["episodeNumber"].int ?? 0)
                + (record["title"].string ?? ""),
             record["airDateUtc"].string, Artwork.poster(record["series"]["images"]))
        case .readarr:
            (id, record["title"].string ?? "",
             LibraryShapes.nonEmpty(record["author"]["authorName"].string) ?? record["authorTitle"].string,
             record["releaseDate"].string, LibraryShapes.bookCover(record["images"]))
        case .lidarr:
            (id, record["title"].string ?? "", record["artist"]["artistName"].string, record["releaseDate"].string,
             Artwork.musicCover(record["images"]))
        }
        return WantedItem(
            air_date: date, app: app.rawValue, id: id, last_search: record["lastSearchTime"].date,
            library_id: library, poster: poster, subtitle: subtitle, title: title
        )
    }

    /// The arr's own job that goes through its whole wanted list.
    public func searchAllWanted(_ app: ArrApp, kind: WantedKind) async throws {
        try await call {
            let name = switch (app, kind) {
            case (.radarr, .missing): "MissingMoviesSearch"
            case (.radarr, .cutoff): "CutoffUnmetMoviesSearch"
            case (.sonarr, .missing): "MissingEpisodeSearch"
            case (.sonarr, .cutoff): "CutoffUnmetEpisodeSearch"
            case (.readarr, .missing): "MissingBookSearch"
            case (.readarr, .cutoff): "CutoffUnmetBookSearch"
            case (.lidarr, .missing): "MissingAlbumSearch"
            case (.lidarr, .cutoff): "CutoffUnmetAlbumSearch"
            }
            _ = try await registry.arr(app.rawValue).send("POST", "/command", json: ["name": .string(name)])
        }
    }

    public func searchAlbum(_ id: Int) async throws {
        try await triggerSearch(.album(id))
    }

    /// Answers in the order a person asks: is it coming, is it blocked, is
    /// anyone looking, and is there anywhere to look. For Lidarr the item is
    /// an album; Readarr has no diagnosis, as on the server.
    public func diagnose(_ app: ArrApp, id: Int) async throws -> Diagnosis {
        try await call {
            let path = switch app {
            case .radarr: "/movie/\(id)"
            case .sonarr: "/series/\(id)"
            case .lidarr: "/album/\(id)"
            case .readarr: throw APIError.unexpectedStatus(404)
            }
            // the server answered 404 for a title it could not read, the arr
            // being away included
            guard let arr = try? registry.arr(app.rawValue) else { throw APIError.unexpectedStatus(404) }
            async let fetched = arr.get(path)
            async let queue = Self.optional { try await arr.get("/queue", query: Diagnose.queueQuery(app)) }
            async let blocklist = Self.optional {
                try await arr.get("/blocklist", query: [
                    "page": "1", "pageSize": "200", "sortKey": "date", "sortDirection": "descending",
                ])
            }
            // cached apart from the tasks card; a diagnosis is rare enough
            // that a fresh-ish read is fine
            async let tasks = Self.optional {
                try await self.cached("diagnose:tasks:\(app.rawValue)", ttl: 120) { try await arr.get("/system/task") }
            }
            async let delays = Self.optional {
                try await self.cached("diagnose:delays:\(app.rawValue)", ttl: 300) { try await arr.get("/delayprofile") }
            }
            async let indexers = Self.optional {
                try await self.cached("diagnose:indexers", ttl: 300) { try await Diagnose.indexerStats(self.registry.arr("prowlarr")) }
            }
            guard let item = try? await fetched else { throw APIError.unexpectedStatus(404) }
            let findings = Diagnose.findings(
                app: app, id: id, item: item, queue: await queue["records"].array,
                blocklist: await blocklist["records"].array, tasks: await tasks.array, delays: await delays.array,
                indexers: await indexers
            )
            return Diagnosis(
                app: app.rawValue, findings: try Diagnose.decode(findings), id: id, title: item["title"].string
            )
        }
    }

    /// One of a diagnosis's inputs: missing, when it could not be read.
    private static func optional(_ fetch: () async throws -> JSON) async -> JSON {
        (try? await fetch()) ?? .null
    }
}

/// The checks behind a diagnosis. Findings are codes with parameters, not
/// sentences: the wording lives with the app (DiagnosisText).
private enum Diagnose {
    /// Worst first, so the screen can lead with what blocks the grab.
    static let levels = ["blocked", "warning", "info", "ok"]
    /// Beyond this an RSS sync is late enough to mention; the scheduler
    /// tolerates a lot of slack, so a smaller window would cry wolf.
    static let rssOverdue: TimeInterval = 3600
    /// Prowlarr files these as warnings, but they say nothing about whether
    /// an indexer can be searched.
    static let healthNotices: Set = ["UpdateCheck", "ApplicationLongTermStatusCheck"]

    struct Finding {
        var code: String
        var level: String
        var params: [String: JSON] = [:]
    }

    static func queueQuery(_ app: ArrApp) -> [String: String?] {
        // without the unknown items the arr leaves out whatever it could not
        // match, which is just what needs a look
        switch app {
        case .radarr: ["pageSize": "50", "includeUnknownMovieItems": "true"]
        case .sonarr: ["pageSize": "50", "includeSeries": "true", "includeUnknownSeriesItems": "true"]
        case .readarr: ["pageSize": "50", "includeUnknownAuthorItems": "true", "includeBook": "true", "includeAuthor": "true"]
        case .lidarr: ["pageSize": "50", "includeUnknownArtistItems": "true", "includeAlbum": "true", "includeArtist": "true"]
        }
    }

    static func findings(
        app: ArrApp, id: Int, item: JSON, queue: [JSON], blocklist: [JSON], tasks: [JSON], delays: [JSON],
        indexers: JSON, now: Date = .now
    ) -> [Finding] {
        var out = queueFindings(queue, id: id, app: app)
        switch app {
        case .radarr:
            out += availabilityFindings(item)
            out += searchFindings(item)
        case .lidarr:
            // an album is searched for only while both it and its artist are
            if !(item["monitored"].bool ?? true) || !(item["artist"]["monitored"].bool ?? true) {
                out.append(Finding(code: "not_monitored", level: "blocked"))
            }
            out += searchFindings(item)
        case .sonarr, .readarr:
            if !(item["monitored"].bool ?? true) { out.append(Finding(code: "not_monitored", level: "blocked")) }
        }
        out += blocklistFindings(blocklist, id: id, app: app)
        out += rssFindings(tasks, now: now)
        out += delayFindings(delays)
        out += indexerFindings(indexers)
        if out.isEmpty {
            // everything checked out, which is itself the answer
            out.append(Finding(code: "nothing_found", level: "info"))
        }
        func rank(_ finding: Finding) -> Int { levels.firstIndex(of: finding.level) ?? levels.count }
        return out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// The first question: is it already on its way? The server's own check
    /// read queue rows already shaped for its queue card, but was handed
    /// Radarr's and Sonarr's raw records, so for those two it never matched;
    /// here every arr's raw record is read for the same fields.
    static func queueFindings(_ records: [JSON], id: Int, app: ArrApp) -> [Finding] {
        let idField = switch app {
        case .radarr: "movieId"
        case .lidarr: "albumId"
        case .sonarr, .readarr: "seriesId"
        }
        return records.filter { $0[idField].int == id }.map { record in
            let errors = record["statusMessages"].array.compactMap { $0["messages"].array.first?.string }
            let state = (LibraryShapes.nonEmpty(record["trackedDownloadState"].string)
                ?? LibraryShapes.nonEmpty(record["status"].string) ?? "").lowercased()
            if let reason = errors.first {
                // a failed import keeps its "downloading" status in the arr, so
                // the errors are the only honest signal
                return Finding(code: "queue_failed", level: "blocked", params: ["reason": .string(reason)])
            } else if ["stalled", "warning"].contains(state) {
                return Finding(code: "queue_stalled", level: "warning", params: ["state": .string(state)])
            } else if (record["sizeleft"].double ?? 0) <= 0 {
                return Finding(code: "queue_importing", level: "info")
            }
            return Finding(code: "queue_downloading", level: "ok", params: ["state": .string(state.isEmpty ? "downloading" : state)])
        }
    }

    /// The commonest real answer for a film, and the least obvious: Radarr
    /// will not search until a film reaches its minimum availability, so a
    /// monitored, unreleased film looks just like a broken indexer.
    static func availabilityFindings(_ movie: JSON) -> [Finding] {
        var out: [Finding] = []
        if !(movie["monitored"].bool ?? true) { out.append(Finding(code: "not_monitored", level: "blocked")) }
        if movie["isAvailable"].bool == false {
            let target = LibraryShapes.nonEmpty(movie["minimumAvailability"].string) ?? "released"
            let date: JSON = switch target {
            case "announced", "inCinemas": movie["inCinemas"]
            case "released": movie["physicalRelease"].isNull ? movie["digitalRelease"] : movie["physicalRelease"]
            default: .null
            }
            var params: [String: JSON] = ["availability": .string(target)]
            if let when = date.date { params["date"] = .string(when.formatted(.iso8601.year().month().day())) }
            out.append(Finding(code: "not_yet_available", level: "blocked", params: params))
        }
        return out
    }

    /// When the arr last went looking: never searched is a different answer
    /// from searched and found nothing.
    static func searchFindings(_ item: JSON) -> [Finding] {
        guard let last = LibraryShapes.nonEmpty(item["lastSearchTime"].string) else {
            return [Finding(code: "never_searched", level: "info")]
        }
        return [Finding(code: "last_searched", level: "info", params: ["when": .string(last)])]
    }

    /// A release grabbed and rejected is not tried again. The record names
    /// the release, not the title, so the join is on the id.
    static func blocklistFindings(_ entries: [JSON], id: Int, app: ArrApp) -> [Finding] {
        let hits = entries.filter { entry in
            switch app {
            // a Lidarr release can span albums, so its record lists them
            case .lidarr: entry["albumIds"].array.contains { $0.int == id }
            case .radarr: entry["movieId"].int == id
            case .sonarr, .readarr: entry["seriesId"].int == id
            }
        }
        guard let first = hits.first else { return [] }
        return [Finding(code: "blocklisted", level: "warning", params: [
            "count": JSON(hits.count), "indexer": first["indexer"], "release": first["sourceTitle"],
            "reason": first["message"],
        ].filter { !$0.value.isNull })]
    }

    /// Nothing is picked up between RSS syncs, so one that has not run for
    /// hours explains a grab that should have happened. The server looked
    /// for its tasks card's rows (and their "overdue") among the arr's raw
    /// tasks and so never found the sync; here the raw task is read, and
    /// what is reported is how long ago it last ran.
    static func rssFindings(_ tasks: [JSON], now: Date) -> [Finding] {
        guard let rss = tasks.first(where: { $0["taskName"].string == "RssSync" }),
              let last = rss["lastExecution"].date
        else { return [] }
        let age = now.timeIntervalSince(last)
        guard age > rssOverdue else { return [] }
        return [Finding(code: "rss_stale", level: "info", params: ["minutes": JSON(Int((age / 60).rounded()))])]
    }

    /// A delay profile holds a grab on purpose; without this the wait looks
    /// like nothing being found.
    static func delayFindings(_ profiles: [JSON]) -> [Finding] {
        profiles.compactMap { profile in
            let usenet = profile["usenetDelay"].int ?? 0, torrent = profile["torrentDelay"].int ?? 0
            guard usenet != 0 || torrent != 0 else { return nil }
            return Finding(code: "delay_profile", level: "info", params: [
                "usenet": JSON(usenet), "torrent": JSON(torrent),
                "bypass": .bool(profile["bypassIfHighestQuality"].bool ?? false),
            ])
        }
    }

    /// Prowlarr's health describes the whole instance and mixes faults with
    /// notices ("New update is available" is a warning there); only faults
    /// count as indexers failing.
    static func indexerFindings(_ stats: JSON) -> [Finding] {
        let enabled = stats["enabled"].int, total = stats["total"].int
        if enabled == 0 { return [Finding(code: "no_indexers", level: "blocked", params: ["total": JSON(total ?? 0)])] }
        let warnings = stats["health"].array.filter {
            ["error", "warning"].contains($0["type"].string ?? "") && !healthNotices.contains($0["source"].string ?? "")
        }
        guard let first = warnings.first else { return [] }
        let shown = LibraryShapes.nonZero(enabled) ?? LibraryShapes.nonZero(total) ?? 0
        return [Finding(code: "indexers_failing", level: "warning", params: [
            "count": JSON(warnings.count), "total": JSON(shown), "message": first["message"],
        ].filter { !$0.value.isNull })]
    }

    /// Prowlarr's indexers and health, as the server's indexer stats read
    /// them for a diagnosis.
    static func indexerStats(_ prowlarr: KeyedClient) async throws -> JSON {
        async let indexers = prowlarr.get("/indexer")
        async let health = prowlarr.get("/health")
        let all = try await indexers.array
        return [
            "enabled": JSON(all.filter { $0["enable"].bool == true }.count),
            "total": JSON(all.count),
            "health": .array(try await health.array.map { ["type": $0["type"], "message": $0["message"], "source": $0["source"]] }),
        ]
    }

    /// The generated finding keeps its parameters in OpenAPI's untyped
    /// container; going through JSON builds it without naming that type.
    static func decode(_ findings: [Finding]) throws -> [DiagnosisFinding] {
        let json = JSON.array(findings.map { ["code": .string($0.code), "level": .string($0.level), "params": .object($0.params)] })
        return try JSONDecoder().decode([DiagnosisFinding].self, from: json.data())
    }
}
