import ArrdeckData
import Foundation

/// What the dashboard, Activity, History and the calendar share, ported from
/// the server's dashboard.py: how each arr is asked for its queue, history
/// and calendar, and how a record becomes a row. One namespace, so the four
/// screens read the arrs exactly alike.
enum DashboardPort {
    // MARK: - Asking the arrs

    /// One page of an arr's queue, with what each arr needs to name an item:
    /// the unknown items are the ones that need a manual import, and the
    /// book, album and their authors are what a person recognises.
    static func queue(_ client: KeyedClient, app: ArrApp) async throws -> JSON {
        let include: [String: String?] = switch app {
        case .radarr: ["includeUnknownMovieItems": "true"]
        case .sonarr: ["includeSeries": "true", "includeUnknownSeriesItems": "true"]
        case .readarr: ["includeUnknownAuthorItems": "true", "includeBook": "true", "includeAuthor": "true"]
        case .lidarr: ["includeUnknownArtistItems": "true", "includeAlbum": "true", "includeArtist": "true"]
        }
        return try await client.get("/queue", query: include.merging(["pageSize": "50"]) { old, _ in old })
    }

    /// One page of history, newest first. Lidarr's records name a file, not
    /// the album it belongs to; with the album and artist attached, a row can
    /// say what was imported.
    static func history(
        _ client: KeyedClient, app: ArrApp, pageSize: Int, page: Int = 1, extra: [String: String?] = [:]
    ) async throws -> JSON {
        var query: [String: String?] = [
            "pageSize": String(pageSize), "page": String(page), "sortKey": "date", "sortDirection": "descending",
        ]
        if app == .lidarr {
            query["includeAlbum"] = "true"
            query["includeArtist"] = "true"
        }
        return try await client.get("/history", query: query.merging(extra) { _, new in new })
    }

    /// One queue record by its id, or a refusal the screen can show.
    static func queueRecord(_ client: KeyedClient, app: ArrApp, id: Int) async throws -> JSON {
        let payload = try await queue(client, app: app)
        guard let record = payload["records"].array.first(where: { $0["id"].int == id }) else {
            throw APIError.refused("queue item not found")
        }
        return record
    }

    // MARK: - Queue

    /// The tracked states where the arr has stopped and is waiting for a
    /// person. importPending is usually brief, but one that lingers is the
    /// "waiting to import" that never finishes.
    static let attentionStates: Set = ["importBlocked", "importPending", "failedPending", "failed"]

    static func needsAttention(state: String?, status: String?) -> Bool {
        state.map(attentionStates.contains) == true || status == "warning" || status == "error"
    }

    static func queueItems(app: ArrApp, payload: JSON) -> [QueueItem] {
        payload["records"].array.map { record in
            let statusMessages = record["statusMessages"].array
            let state = record["trackedDownloadState"].string
            let status = record["trackedDownloadStatus"].string
            return QueueItem(
                album_id: app == .lidarr ? record["albumId"].nonZero : nil,
                app: app.rawValue,
                artist_id: app == .lidarr ? record["artistId"].nonZero : nil,
                book_id: record["bookId"].int,
                episode_id: record["episodeId"].int,
                error_message: record["errorMessage"].nonEmpty,
                errors: statusMessages.compactMap { $0["messages"].array.first?.string },
                estimated_completion: record["estimatedCompletionTime"].string,
                id: record["id"].int ?? 0,
                movie_id: record["movieId"].int,
                needs_attention: needsAttention(state: state, status: status),
                series_id: record["seriesId"].int,
                size: record["size"].double ?? 0,
                size_left: record["sizeleft"].double ?? 0,
                status: record["status"].string ?? "unknown",
                status_messages: statusMessages.map {
                    .init(messages: $0["messages"].array.compactMap(\.string), title: $0["title"].string ?? "")
                },
                time_left: record["timeleft"].string,
                title: queueTitle(app: app, record: record),
                tracked_state: state,
                tracked_status: status
            )
        }
    }

    /// The release name is what the arr calls an item; a show and episode, a
    /// book and author, an album and artist are what a person recognises.
    static func queueTitle(app: ArrApp, record: JSON) -> String {
        let title = record["title"].string ?? ""
        switch app {
        case .sonarr where record["series"].truthy:
            return "\(record["series"]["title"].string ?? "") — \(title)"
        case .readarr where record["book"].truthy || record["author"].truthy:
            return joined(record["author"]["authorName"].nonEmpty, record["book"]["title"].nonEmpty ?? title)
        case .lidarr where record["album"].truthy || record["artist"].truthy:
            return joined(record["artist"]["artistName"].nonEmpty, record["album"]["title"].nonEmpty ?? title)
        default:
            return title
        }
    }

    // MARK: - History

    /// Friendly labels for the arrs' event types; unknown ones pass through.
    static let eventLabels = [
        "grabbed": "fetched",
        "downloadFolderImported": "imported",
        "downloadFailed": "failed",
        "downloadIgnored": "ignored",
        "movieFileDeleted": "deleted",
        "episodeFileDeleted": "deleted",
        "movieFileRenamed": "renamed",
        "episodeFileRenamed": "renamed",
        // Readarr's names for the same events
        "bookFileImported": "imported",
        "bookImportIncomplete": "incomplete",
        "bookFileDeleted": "deleted",
        "bookFileRenamed": "renamed",
        "bookFileRetagged": "renamed",
        // and Lidarr's: a track per file, and the download as a whole
        "trackFileImported": "imported",
        "downloadImported": "imported",
        "artistFolderImported": "imported",
        "albumImportIncomplete": "incomplete",
        "trackFileDeleted": "deleted",
        "trackFileRenamed": "renamed",
        "trackFileRetagged": "renamed",
    ]

    static func label(_ record: JSON) -> String {
        let raw = record["eventType"].string ?? ""
        return eventLabels[raw] ?? raw
    }

    /// A Lidarr record as "Artist — Album", or its own source title.
    static func albumTitle(_ record: JSON) -> String {
        guard let album = record["album"]["title"].nonEmpty else { return record["sourceTitle"].string ?? "" }
        return joined(record["artist"]["artistName"].nonEmpty, album)
    }

    /// What one row of history stands for. Lidarr records a track at a time,
    /// and a manual import has no download id to tie them together, so its
    /// records group by album and hour instead: an album is one row, not one
    /// per track.
    static func historyKey(app: ArrApp, record: JSON) -> String {
        if app == .lidarr, !record["downloadId"].truthy, let album = record["albumId"].nonZero {
            return "album:\(album):\((record["date"].string ?? "").prefix(13))"
        }
        return record["downloadId"].nonEmpty ?? record["sourceTitle"].nonEmpty
            ?? record["id"].int.map(String.init) ?? "None"
    }

    /// History records grouped by download (falling back to the release
    /// title), so each release shows once with a tag for everything that
    /// happened to it. Dates stay the arr's own strings and compare as
    /// strings, as the server's did: one arr writes them all alike.
    static func consolidateHistory(app: ArrApp, payload: JSON, limit: Int = 15) -> [HistoryItem] {
        struct Group {
            var title = ""
            var date: String
            var quality: String?
            var events: [(type: String, date: String)] = []
            var movieID: Int?, seriesID: Int?, bookID: Int?, albumID: Int?
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for record in payload["records"].array {
            let key = historyKey(app: app, record: record)
            let date = record["date"].string ?? ""
            let quality = record["quality"]["quality"]["name"].string
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(date: date, quality: quality)
            }
            var group = groups[key]!
            group.movieID = orElse(group.movieID, record["movieId"].int)
            group.seriesID = orElse(group.seriesID, record["seriesId"].int)
            group.bookID = orElse(group.bookID, record["bookId"].int)
            if app == .lidarr {
                // the album page this row opens; other arrs' rows never carry it
                group.albumID = JSON(orElse(group.albumID, record["albumId"].int)).nonZero
            }
            if group.title.isEmpty {
                group.title = app == .lidarr ? albumTitle(record) : record["sourceTitle"].string ?? ""
            }
            group.date = max(group.date, date)
            if group.quality?.isEmpty ?? true { group.quality = quality }
            group.events.append((label(record), date))
            groups[key] = group
        }
        let newest = stableSorted(order.compactMap { groups[$0] }) { $0.date > $1.date }.prefix(limit)
        return newest.map { group in
            // chronological tags, one per type: each type's first occurrence
            var seen: Set<String> = []
            let events = stableSorted(group.events) { $0.date < $1.date }.filter { seen.insert($0.type).inserted }
            return HistoryItem(
                album_id: group.albumID, app: app.rawValue, book_id: group.bookID, date: group.date,
                events: events.map { HistoryEvent(date: $0.date, _type: $0.type) },
                movie_id: group.movieID, quality: group.quality, series_id: group.seriesID, title: group.title
            )
        }
    }

    // MARK: - Calendar

    /// A film's upcoming release inside [start, end]: in cinemas or digital.
    /// Disc dates are left out on purpose, and nothing outside the window
    /// stands in for one inside it.
    static func releaseInfo(_ movie: JSON, start: String, end: String) -> (date: String, kind: String)? {
        let candidates = [(movie["inCinemas"], "cinema"), (movie["digitalRelease"], "digital")]
        return candidates
            .compactMap { date, kind in date.nonEmpty.map { (date: $0, kind: kind) } }
            .filter { start <= String($0.date.prefix(10)) && String($0.date.prefix(10)) <= end }
            .min { ($0.date, $0.kind) < ($1.date, $1.kind) }
    }

    static func calendarItems(app: ArrApp, entries: JSON, start: String, end: String) -> [CalendarItem] {
        let entries = entries.array
        switch app {
        case .radarr:
            return entries.compactMap { movie in
                // a physical-only release in this window
                guard let release = releaseInfo(movie, start: start, end: end) else { return nil }
                return CalendarItem(
                    app: app.rawValue, date: release.date, has_file: movie["hasFile"].bool ?? false,
                    item_id: movie["id"].int, poster: Artwork.poster(movie["images"]), release_type: release.kind,
                    title: movie["title"].string ?? ""
                )
            }
        case .sonarr:
            return entries.map { episode in
                let code = String(
                    format: "S%02dE%02d", episode["seasonNumber"].int ?? 0, episode["episodeNumber"].int ?? 0
                )
                return CalendarItem(
                    app: app.rawValue, date: episode["airDateUtc"].string,
                    extra: "\(code) \(episode["title"].string ?? "")",
                    finale_type: episode["finaleType"].string, has_file: episode["hasFile"].bool ?? false,
                    item_id: episode["seriesId"].int, poster: Artwork.poster(episode["series"]["images"]),
                    title: episode["series"]["title"].string ?? ""
                )
            }
        case .readarr:
            return entries.map { book in
                CalendarItem(
                    app: app.rawValue, date: book["releaseDate"].string, extra: book["author"]["authorName"].string,
                    has_file: (book["statistics"]["bookFileCount"].int ?? 0) > 0, item_id: book["id"].int,
                    poster: Artwork.bookCover(book["images"]), title: book["title"].string ?? ""
                )
            }
        case .lidarr:
            return entries.map { album in
                CalendarItem(
                    app: app.rawValue, date: album["releaseDate"].string, extra: album["artist"]["artistName"].string,
                    has_file: (album["statistics"]["trackFileCount"].int ?? 0) > 0, item_id: album["id"].int,
                    poster: Artwork.musicCover(album["images"]), title: album["title"].string ?? ""
                )
            }
        }
    }

    // MARK: - Python's ways

    /// `current or new`: keep an id once a record supplied a non-zero one.
    static func orElse(_ current: Int?, _ new: Int?) -> Int? {
        if let current, current != 0 { current } else { new }
    }

    static func joined(_ person: String?, _ work: String) -> String {
        person.map { "\($0) — \(work)" } ?? work
    }

    /// Sorted with ties left in the order they came, as Python's sort leaves
    /// them.
    static func stableSorted<T>(_ items: [T], by before: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { before($0.element, $1.element) || (!before($1.element, $0.element) && $0.offset < $1.offset) }
            .map(\.element)
    }

    /// An ISO 8601 UTC timestamp, with the fraction only when there is one.
    static func iso(_ date: Date) -> String {
        let fractional = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0
        return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: fractional))
    }
}

extension DirectBackend {
    /// An aggregate across the arrs, one block each: Radarr and Sonarr always
    /// (a missing one reads "not configured"), Readarr and Lidarr only once
    /// set up, so a stack without them gets no permanent offline card.
    /// `key` prefixes each arr's stale-fallback key, as the server's did.
    func dashboardArrBlocks<T: Sendable & Equatable>(
        _ key: String, _ fetch: @escaping @Sendable (ArrApp, KeyedClient) async throws -> T
    ) async -> [ArrApp: Block<T>] {
        let apps = ArrApp.allCases.filter { $0 == .radarr || $0 == .sonarr || registry.isConfigured($0.rawValue) }
        return await withTaskGroup(of: (ArrApp, Block<T>).self) { group in
            for app in apps {
                group.addTask {
                    (app, await self.guarded("\(key):\(app.rawValue)") {
                        try await fetch(app, try self.registry.arr(app.rawValue))
                    })
                }
            }
            var out: [ArrApp: Block<T>] = [:]
            for await (app, block) in group { out[app] = block }
            return out
        }
    }

    /// The arrs a merged list reads, in the server's order: those set up,
    /// Radarr and Sonarr always.
    func dashboardListedArrs(_ apps: [ArrApp] = ArrApp.allCases) -> [ArrApp] {
        apps.filter { $0 == .radarr || $0 == .sonarr || registry.isConfigured($0.rawValue) }
    }
}
