import ArrdeckData
import Foundation

/// Rescuing a stuck download and importing a finished torrent by hand, ported
/// from the server's importing.py (and dashboard.py's attention list). The
/// arr's own placement of a file, and the ManualImport file it becomes, are
/// the force import's (`DashboardForceImport`): a hand-picked target or a
/// corrected quality is written into the candidate the way the arr would have
/// matched it, and goes through the same mapping.
extension DirectBackend: ManualImportAPI {
    /// Every queue item, across the arrs set up, that waits for a person. An
    /// arr that is down is named in `unavailable` rather than failing the
    /// list; there is no last good queue to fall back on, as on the server.
    public func attention() async throws -> Attention {
        let apps = ArrApp.allCases.filter { registry.isConfigured($0.rawValue) }
        let queues = await withTaskGroup(of: (ArrApp, [QueueItem]?).self) { group in
            for app in apps {
                group.addTask {
                    let items = try? await DashboardPort.queueItems(
                        app: app, payload: DashboardPort.queue(self.registry.arr(app.rawValue), app: app)
                    )
                    return (app, items)
                }
            }
            var out: [ArrApp: [QueueItem]] = [:]
            for await (app, items) in group { out[app] = items }
            return out
        }
        var items: [QueueItem] = []
        var unavailable: [String] = []
        for app in apps {
            guard let queue = queues[app] else {
                unavailable.append(app.rawValue)
                continue
            }
            items += queue.filter { $0.needs_attention == true }
        }
        return Attention(count: items.count, items: items, unavailable: unavailable)
    }

    public func importCandidates(_ source: ImportSource) async throws -> [ImportCandidate] {
        try await call {
            switch source {
            case let .queue(app, itemID):
                let client = try registry.arr(app.rawValue)
                let download = try await ManualImportPort.download(client, app: app, itemID: itemID)
                return ManualImportPort.describeAll(app: app, try await ManualImportPort.candidates(client, download: download))
            case let .torrent(app, torrentClient, torrentID):
                let client = try registry.arr(app.rawValue)
                let content = try await torrentContent(torrentClient, torrentID)
                return ManualImportPort.describeAll(
                    app: app, try await torrentCandidates(app: app, client, torrentClient: torrentClient, content: content)
                )
            }
        }
    }

    /// What a file's quality and languages can be set to: the qualities in
    /// the arr's order, the languages by name.
    public func importOptions(_ app: ArrApp) async throws -> ImportOptions {
        try await call {
            let table = try await importOptionTable(app, try registry.arr(app.rawValue))
            return ImportOptions(
                languages: DashboardPort.stableSorted(table.languageOrder.compactMap { table.languages[$0] }) { $0.name < $1.name },
                qualities: table.qualityOrder.map { ImportChoice(id: $0, name: table.qualities[$0]?["name"].string ?? "") }
            )
        }
    }

    public func startImport(_ request: ImportRequest) async throws -> ImportCommand {
        try await call {
            let app = request.app
            let client = try registry.arr(app.rawValue)
            let files: [JSON]
            let mode: String
            switch request {
            case let .plain(_, body):
                // every picked file on the arr's own match and detection
                let download = try await ManualImportPort.download(client, app: app, itemID: body.item_id)
                let wanted = Set(body.paths)
                files = try await ManualImportPort.candidates(client, download: download)
                    .filter { $0["path"].string.map(wanted.contains) ?? false }
                    .compactMap { DashboardForceImport.file(app: app, candidate: $0, download: download) }
                guard !files.isEmpty else { throw APIError.refused("none of the selected files could be mapped") }
                mode = body.mode?.rawValue ?? "auto"
            case let .assign(_, body):
                let download = try await ManualImportPort.download(client, app: app, itemID: body.item_id)
                let candidates = try await ManualImportPort.candidates(client, download: download)
                files = try await importFiles(app: app, client, candidates: candidates, choices: body.files, download: download)
                mode = body.mode?.rawValue ?? "auto"
            case let .torrent(_, body):
                // the folder is worked out again, and every path must be one
                // the arr found in it
                let torrentClient = body.client == .qbittorrent ? TorrentClient.qbittorrent : .transmission
                let content = try await torrentContent(torrentClient, body.torrent_id)
                let candidates = try await torrentCandidates(app: app, client, torrentClient: torrentClient, content: content)
                files = try await importFiles(app: app, client, candidates: candidates, choices: body.files, download: nil)
                // No tracked download, and for the arr that turns auto into a
                // move: copy keeps the torrent's files (a hardlink when the arr
                // is set to use them).
                let chosen = body.mode?.rawValue ?? "auto"
                mode = chosen == "auto" ? "copy" : chosen
            }
            let command = try await client.send(
                "POST", "/command", json: ["name": "ManualImport", "files": .array(files), "importMode": .string(mode)]
            )
            return ManualImportPort.command(app: app, command)
        }
    }

    public func importCommand(app: ArrApp, id: Int) async throws -> ImportCommand {
        try await call {
            ManualImportPort.command(app: app, try await registry.arr(app.rawValue).get("/command/\(id)"))
        }
    }
}

// MARK: - Building the import

extension DirectBackend {
    /// The qualities and languages a file can be imported as, ten minutes
    /// under the server's key. Readarr's and Lidarr's files carry no
    /// language, so there are none to offer.
    func importOptionTable(_ app: ArrApp, _ client: KeyedClient) async throws -> ImportOptionTable {
        try await cached("import-options:\(app.rawValue)", ttl: 600) {
            async let definitions = client.get("/qualitydefinition")
            let languages = app == .readarr || app == .lidarr ? [] : try await client.get("/language").array
            return ImportOptionTable(definitions: try await definitions.array, languages: languages)
        }
    }

    /// ManualImport files for the user's choices, checked against what the
    /// arr actually found: a path it did not offer is refused, never passed
    /// through. A file without a target keeps the arr's own match, so one
    /// command covers both.
    private func importFiles(
        app: ArrApp, _ client: KeyedClient, candidates: [JSON], choices: [ImportFile], download: String?
    ) async throws -> [JSON] {
        var byPath: [String: JSON] = [:]
        for candidate in candidates {
            if let path = candidate["path"].string { byPath[path] = candidate }
        }
        let overriding = choices.contains { $0.quality_id != nil || !($0.language_ids ?? []).isEmpty }
        let options = overriding ? try await importOptionTable(app, client) : nil
        for choice in choices where byPath[choice.path] == nil {
            throw APIError.refused("no candidate for \(ManualImportPort.quoted(choice.path))")
        }
        if app == .lidarr {
            byPath.merge(try await albumPicks(client, byPath: byPath, choices: choices, download: download)) { _, new in new }
        }
        var files: [JSON] = []
        for var choice in choices {
            // a picked album was matched to its tracks above; the candidate now
            // carries it as the file's own match
            if app == .lidarr, choice.album_id != nil { choice.album_id = nil }
            let candidate = byPath[choice.path]!
            var fields = candidate.object
            fields["quality"] = try ManualImportPort.quality(candidate, choice, options)
            fields["languages"] = try ManualImportPort.languages(candidate, choice, options)
            fields.merge(try await pickedMatch(app: app, client, candidate: candidate, choice: choice)) { _, new in new }
            guard let file = DashboardForceImport.file(app: app, candidate: .object(fields), download: download) else {
                throw APIError.refused("nothing to import")
            }
            files.append(file)
        }
        guard !files.isEmpty else { throw APIError.refused("nothing to import") }
        return files
    }

    /// The user's pick when there is one, else the arr's own match, written
    /// as the candidate fields the arr's own match lives in. Picking anything
    /// sets the arr's match aside entirely.
    private func pickedMatch(app: ArrApp, _ client: KeyedClient, candidate: JSON, choice: ImportFile) async throws -> [String: JSON] {
        let episodeIDs = choice.episode_ids ?? []
        let picked = [choice.movie_id, choice.series_id, choice.book_id, choice.album_id].contains { ($0 ?? 0) != 0 }
            || !episodeIDs.isEmpty
        let own = picked ? nil : DashboardForceImport.target(app: app, candidate: candidate)
        switch app {
        case .radarr:
            guard let movie = JSON(choice.movie_id).nonZero ?? own?["movieId"]?.int else {
                throw APIError.refused("a movie must be chosen for each file")
            }
            return ["movie": ["id": JSON(movie)]]
        case .readarr:
            if let book = JSON(choice.book_id).nonZero { return try await bookMatch(client, book: book) }
            guard own != nil else { throw APIError.refused("a book must be chosen for each file") }
            return [:]
        case .lidarr:
            guard own != nil else { throw APIError.refused("an album must be chosen for each file") }
            return [:]
        case .sonarr:
            let series = JSON(choice.series_id).nonZero ?? own?["seriesId"]?.int
            let episodes = episodeIDs.isEmpty ? (own?["episodeIds"]?.array.compactMap(\.int) ?? []) : episodeIDs
            guard let series, !episodes.isEmpty else {
                throw APIError.refused("a series and at least one episode must be chosen")
            }
            return ["series": ["id": JSON(series)], "episodes": .array(episodes.map { ["id": JSON($0)] })]
        }
    }

    /// Readarr imports into an edition, not just a book: a picked book goes
    /// to its monitored edition, the one Readarr's own import screen uses.
    private func bookMatch(_ readarr: KeyedClient, book id: Int) async throws -> [String: JSON] {
        let book = try await readarr.get("/book/\(id)")
        let editions = try await readarr.get("/edition", query: ["bookId": String(id)]).array
        let edition = editions.first { $0["monitored"].truthy }
        guard let author = book["authorId"].nonZero, let edition,
              edition["foreignEditionId"].truthy
        else { throw APIError.refused("Readarr has no monitored edition for that book") }
        return ["author": ["id": JSON(author)], "book": ["id": JSON(id)], "foreignEditionId": edition["foreignEditionId"]]
    }

    /// Files pointed at an album by hand, matched to its tracks by Lidarr,
    /// the way its own import screen does it: every file picked for the same
    /// album in one request, since Lidarr shares the album's tracks out
    /// across the set. The monitored release is the starting point; Lidarr
    /// may settle on another release the files fit better.
    private func albumPicks(
        _ lidarr: KeyedClient, byPath: [String: JSON], choices: [ImportFile], download: String?
    ) async throws -> [String: JSON] {
        var order: [Int] = []
        var picks: [Int: [ImportFile]] = [:]
        for choice in choices {
            guard let album = JSON(choice.album_id).nonZero else { continue }
            if picks[album] == nil { order.append(album) }
            picks[album, default: []].append(choice)
        }
        var matched: [String: JSON] = [:]
        for albumID in order {
            let album = try await lidarr.get("/album/\(albumID)")
            let releases = album["releases"].array
            guard album["artistId"].truthy,
                  let release = releases.first(where: { $0["monitored"].truthy }) ?? releases.first
            else { throw APIError.refused("Lidarr has no release for that album") }
            let items: [JSON] = (picks[albumID] ?? []).map { choice in
                let candidate = byPath[choice.path] ?? .null
                var item: [String: JSON] = [
                    "path": .string(choice.path), "artistId": album["artistId"], "albumId": JSON(albumID),
                    "albumReleaseId": release["id"], "quality": candidate["quality"],
                    "indexerFlags": candidate["indexerFlags"].truthy ? candidate["indexerFlags"] : 0,
                    "disableReleaseSwitching": false,
                ]
                if let download, !download.isEmpty { item["downloadId"] = .string(download) }
                if !candidate["id"].isNull { item["id"] = candidate["id"] }
                return .object(item)
            }
            let results = try await lidarr.send("POST", "/manualimport", json: .array(items), timeout: 120)
            for result in results.array {
                guard let path = result["path"].string, let current = byPath[path] else { continue }
                guard DashboardForceImport.target(app: .lidarr, candidate: result) != nil else {
                    let title = album["title"].nonEmpty ?? "that album"
                    throw APIError.refused("Lidarr could not match \(ManualImportPort.quoted(path)) to a track on \(title)")
                }
                // what the first scan knew (quality, flags) stays, under the new match
                matched[path] = current
                    .setting("artist", result["artist"].truthy ? result["artist"] : ["id": album["artistId"]])
                    .setting("album", result["album"].truthy ? result["album"] : ["id": JSON(albumID)])
                    .setting("albumReleaseId", result["albumReleaseId"])
                    .setting("tracks", result["tracks"].truthy ? result["tracks"] : [])
            }
        }
        let missing = order.flatMap { picks[$0] ?? [] }.map(\.path).first { matched[$0] == nil }
        if let missing { throw APIError.refused("Lidarr did not match \(ManualImportPort.quoted(missing)) to that album") }
        return matched
    }
}

// MARK: - A finished torrent no arr is tracking

extension DirectBackend {
    /// Where a finished torrent's content lives, from the torrent client
    /// itself. Nothing here comes from the request except which torrent.
    func torrentContent(_ torrentClient: TorrentClient, _ torrentID: String) async throws -> TorrentContent {
        let numeric = torrentClient == .transmission && !torrentID.isEmpty
            && torrentID.allSatisfy { $0.isASCII && $0.isNumber }
        guard torrentID.wholeMatch(of: /[0-9a-fA-F]{40}|[0-9a-fA-F]{64}/) != nil || numeric else {
            throw APIError.refused("torrent not found")
        }
        let done: Bool, savePath: String, content: String, hash: String
        switch torrentClient {
        case .qbittorrent:
            let found = try await registry.qbittorrent().get("/api/v2/torrents/info", query: ["hashes": torrentID]).array
            guard let torrent = found.first(where: { ($0["hash"].string ?? "").lowercased() == torrentID.lowercased() }) else {
                throw APIError.refused("torrent not found")
            }
            done = (torrent["progress"].double ?? 0) >= 1
            savePath = torrent["save_path"].string ?? ""
            // root_path is the torrent's top folder; a single-file torrent has
            // none, and content_path is then the file itself
            content = torrent["root_path"].nonEmpty ?? torrent["content_path"].nonEmpty
                ?? ManualImportPort.join(savePath, torrent["name"].string ?? "")
            hash = torrent["hash"].nonEmpty ?? torrentID
        case .transmission:
            let id: JSON = numeric ? (Int(torrentID).map { JSON($0) } ?? .string(torrentID)) : .string(torrentID)
            let found = try await registry.transmission()
                .rpc("torrent-get", ["ids": [id], "fields": DashboardPort.transmissionFields])["torrents"].array
            guard let torrent = found.first else { throw APIError.refused("torrent not found") }
            done = (torrent["percentDone"].double ?? 0) >= 1
            savePath = torrent["downloadDir"].string ?? ""
            content = ManualImportPort.join(savePath, torrent["name"].string ?? "")
            hash = torrent["hashString"].string ?? ""
        }
        guard done else { throw APIError.refused("the torrent has not finished downloading") }
        return TorrentContent(folder: try ManualImportPort.inside(savePath, content), hash: hash)
    }

    /// What the arr makes of the torrent's folder. A download an arr already
    /// tracks is fixed from its queue item instead, where the arr keeps its
    /// own bookkeeping; an empty answer is checked against a listing of the
    /// parent, so "not mounted there" is said rather than guessed at.
    func torrentCandidates(
        app: ArrApp, _ client: KeyedClient, torrentClient: TorrentClient, content: TorrentContent
    ) async throws -> [JSON] {
        if !content.hash.isEmpty, let tracker = await trackedBy(content.hash) {
            throw APIError.refused(
                "\(Services.label(tracker.rawValue)) is already tracking this download; "
                    + "fix it from its queue item (Needs attention) instead"
            )
        }
        let folder = content.folder
        let candidates = try await client.get(
            "/manualimport", query: ["folder": folder, "filterExistingFiles": "false"], timeout: 120
        ).array
        if !candidates.isEmpty { return candidates }
        let (parent, name) = ManualImportPort.split(folder)
        let listing = try await client.get(
            "/filesystem", query: ["path": ManualImportPort.trimmingSlashes(parent) + "/", "includeFiles": "true"]
        )
        let seen = Set((listing["directories"].array + listing["files"].array).compactMap { $0["name"].string })
        guard seen.contains(name) else {
            let arr = Services.label(app.rawValue), torrents = Services.label(torrentClient.rawValue)
            throw APIError.refused(
                "\(arr) can't see \(folder): \(torrents) saved it to a folder that isn't mounted at the same path "
                    + "in \(arr). Mount it there, or add a remote path mapping in \(arr)."
            )
        }
        return []
    }

    /// The arr that has this download in its queue, if any. One that is down
    /// tracks nothing that can be seen.
    private func trackedBy(_ hash: String) async -> ArrApp? {
        for app in ArrApp.allCases {
            guard let client = try? registry.arr(app.rawValue),
                  let payload = try? await DashboardPort.queue(client, app: app)
            else { continue }
            if payload["records"].array.contains(where: { ($0["downloadId"].string ?? "").lowercased() == hash.lowercased() }) {
                return app
            }
        }
        return nil
    }
}

/// A finished torrent's content: the folder (or single file) to scan, and
/// the info hash the arrs' queues would know it by.
struct TorrentContent: Sendable {
    var folder: String
    var hash: String
}

/// The qualities and languages an import can be set to, keyed by id, and in
/// the arr's own order, which is how the qualities are offered.
struct ImportOptionTable: Sendable {
    var qualities: [Int: JSON] = [:]
    var qualityOrder: [Int] = []
    var languages: [Int: ImportChoice] = [:]
    var languageOrder: [Int] = []

    init(definitions: [JSON], languages: [JSON]) {
        for definition in definitions where definition["quality"].truthy {
            guard let id = definition["quality"]["id"].int else { continue }
            if qualities[id] == nil { qualityOrder.append(id) }
            qualities[id] = definition["quality"]
        }
        // negative ids ("Any", "Original") are profile wildcards, not
        // something a file can be
        for language in languages {
            guard let id = language["id"].int, id >= 0 else { continue }
            if self.languages[id] == nil { languageOrder.append(id) }
            self.languages[id] = ImportChoice(id: id, name: language["name"].string ?? "")
        }
    }
}

/// importing.py's mapping, shared by the routes above.
enum ManualImportPort {
    /// The download a queue item stands for, which is how the arr is asked
    /// what it found.
    static func download(_ client: KeyedClient, app: ArrApp, itemID: Int) async throws -> String {
        let record = try await DashboardPort.queueRecord(client, app: app, id: itemID)
        guard let download = record["downloadId"].nonEmpty else {
            throw APIError.refused("queue item not found")
        }
        return download
    }

    /// Everything the arr found in a download's folder, including the files
    /// a force import skips.
    static func candidates(_ client: KeyedClient, download: String) async throws -> [JSON] {
        try await client.get("/manualimport", query: ["downloadId": download, "filterExistingFiles": "false"]).array
    }

    // MARK: Describing a candidate

    static func describeAll(app: ArrApp, _ candidates: [JSON]) -> [ImportCandidate] {
        let described = candidates.map { describe(app: app, $0) }
        // an album arrives as a dozen files in no particular order; by path
        // they read in track order, the way they are usually named
        return app == .lidarr ? DashboardPort.stableSorted(described) { $0.path < $1.path } : described
    }

    static func describe(app: ArrApp, _ candidate: JSON) -> ImportCandidate {
        let title: String, subtitle: String?
        switch app {
        case .radarr:
            (title, subtitle) = (candidate["movie"]["title"].string ?? "", nil)
        case .readarr:
            (title, subtitle) = (candidate["book"]["title"].string ?? "", candidate["author"]["authorName"].string)
        case .lidarr:
            (title, subtitle) = (candidate["album"]["title"].string ?? "", trackLabel(candidate))
        case .sonarr:
            let episodes = candidate["episodes"].array
            var code: String?
            if let first = episodes.first, let season = first["seasonNumber"].int, let number = first["episodeNumber"].int {
                code = String(format: "S%02dE%02d", season, number) + (episodes.count > 1 ? " +\(episodes.count - 1)" : "")
            }
            (title, subtitle) = (candidate["series"]["title"].string ?? "", code)
        }
        let path = candidate["path"].string ?? ""
        let quality = candidate["quality"]["quality"]
        let languages = candidate["languages"].array
        return ImportCandidate(
            importable: DashboardForceImport.file(app: app, candidate: candidate, download: nil) != nil,
            language_ids: languages.compactMap { $0["id"].int },
            languages: languages.map { $0["name"].string ?? "" },
            name: candidate["name"].nonEmpty
                ?? String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? ""),
            path: path,
            quality: quality["name"].string,
            quality_id: quality["id"].int,
            rejections: candidate["rejections"].array.map { rejection in
                if case .object = rejection { rejection["reason"].string ?? "" } else { rejection.printed }
            },
            size: candidate["size"].whole ?? 0,
            subtitle: subtitle,
            title: title
        )
    }

    /// "Artist · 3. Track title", "+N" when a file holds several tracks.
    static func trackLabel(_ candidate: JSON) -> String? {
        let artist = candidate["artist"]["artistName"].string
        let tracks = candidate["tracks"].array
        var track: String?
        if let first = tracks.first {
            let number = first["trackNumber"].truthy ? first["trackNumber"] : first["absoluteTrackNumber"]
            track = number.truthy ? "\(number.printed). \(first["title"].string ?? "")" : first["title"].string
            if tracks.count > 1 { track = (track ?? "") + " +\(tracks.count - 1)" }
        }
        let parts = [artist, track].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Overrides

    /// The arr's own quality, or the one picked, keeping the revision
    /// (proper, repack) the arr parsed from the name.
    static func quality(_ candidate: JSON, _ choice: ImportFile, _ options: ImportOptionTable?) throws -> JSON {
        let detected = candidate["quality"]
        guard let id = choice.quality_id else {
            guard detected.truthy else {
                throw APIError.refused("the arr could not determine a quality for \(quoted(choice.path))")
            }
            return detected
        }
        guard let chosen = options?.qualities[id] else { throw APIError.refused("unknown quality id \(id)") }
        let revision: JSON = detected["revision"].truthy
            ? detected["revision"] : ["version": 1, "real": 0, "isRepack": false]
        return ["quality": chosen, "revision": revision]
    }

    static func languages(_ candidate: JSON, _ choice: ImportFile, _ options: ImportOptionTable?) throws -> JSON {
        guard let ids = choice.language_ids, !ids.isEmpty else { return candidate.object["languages"] ?? [] }
        let known = options?.languages ?? [:]
        let unknown = ids.filter { known[$0] == nil }
        guard unknown.isEmpty else { throw APIError.refused("unknown language ids \(unknown)") }
        return .array(ids.compactMap { known[$0] }.map { ["id": JSON($0.id), "name": .string($0.name)] })
    }

    // MARK: The arr's command

    /// What the screen needs to say how an import went, from the arr's
    /// command.
    static func command(app: ArrApp, _ command: JSON) -> ImportCommand {
        let status = command["status"].nonEmpty ?? "queued"
        let done = ["completed", "failed", "aborted", "cancelled", "orphaned"].contains(status)
        var message = command["message"].nonEmpty
        // a crash leaves the message at "Failed" and the reason in a full .NET
        // stack trace, whose first line is the part a person can act on
        let trace = (command["exception"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
        if status == "failed", let first = trace.first, message == nil || message == "Failed" {
            message = String(first)
        }
        // "Manually imported 3 files", the arrs' closing progress line
        let imported = message?.firstMatch(of: /imported (\d+) files?/.ignoresCase()).flatMap { Int($0.1) }
        return ImportCommand(
            app: app.rawValue,
            done: done,
            id: command["id"].nonZero ?? 0,
            imported: imported,
            message: message,
            ok: done ? status == "completed" && command["result"].string != "unsuccessful" : nil,
            result: command["result"].string,
            status: status
        )
    }

    // MARK: Paths, the way the server's posixpath read them

    /// `path`, normalised, provided it lies strictly under `savePath`. The
    /// torrent client is the only source of both, but a renamed torrent can
    /// still carry "../" in its name.
    static func inside(_ savePath: String, _ path: String) throws -> String {
        let root = normpath(savePath), full = normpath(path)
        let rootParts = root.split(separator: "/"), fullParts = full.split(separator: "/")
        guard root.hasPrefix("/"), full.hasPrefix("/"), fullParts.starts(with: rootParts), full != root else {
            throw APIError.refused("\(quoted(path)) is not inside the torrent's save path \(quoted(savePath))")
        }
        return full
    }

    /// posixpath.normpath: purely lexical, so it never asks the device's own
    /// file system about a path that only exists on the server.
    static func normpath(_ path: String) -> String {
        guard !path.isEmpty else { return "." }
        // POSIX lets exactly two leading slashes mean something else
        let leading = path.hasPrefix("//") && !path.hasPrefix("///") ? 2 : path.hasPrefix("/") ? 1 : 0
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part != ".." {
                parts.append(part)
            } else if leading == 0 && (parts.isEmpty || parts.last == "..") {
                parts.append(part)
            } else if !parts.isEmpty {
                parts.removeLast()
            }
        }
        let joined = String(repeating: "/", count: leading) + parts.joined(separator: "/")
        return joined.isEmpty ? "." : joined
    }

    static func join(_ base: String, _ name: String) -> String {
        if name.hasPrefix("/") { return name }
        return base.isEmpty || base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// posixpath.split: everything before the last slash, and after it.
    static func split(_ path: String) -> (head: String, tail: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let head = String(path[...slash]), tail = String(path[path.index(after: slash)...])
        return (head.allSatisfy { $0 == "/" } ? head : trimmingSlashes(head), tail)
    }

    static func trimmingSlashes(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A path as the server's messages quoted it (Python's repr).
    static func quoted(_ text: String) -> String {
        text.contains("'") && !text.contains("\"") ? "\"\(text)\"" : "'\(text)'"
    }
}
