import ArrdeckData
import Foundation

/// Interactive search, renaming, adding torrents, the torrent detail sheet's
/// writes and the library's bulk actions, from the server's releases.py,
/// importing.py, torrentactions.py and library.py.
extension DirectBackend: ExtrasAPI {
    public func releases(_ target: ReleaseTarget) async throws -> [ArrRelease] {
        try await call {
            let query: [String: String?] = switch target {
            case let .movie(id): ["movieId": "\(id)"]
            // Sonarr will not search a whole series, only a season or an episode
            case let .season(series, season): ["seriesId": "\(series)", "seasonNumber": "\(season)"]
            case let .episode(_, episode): ["episodeId": "\(episode)"]
            case let .book(id): ["bookId": "\(id)"]
            case let .album(id): ["albumId": "\(id)"]
            }
            // the arr asks every indexer before it answers, which takes a while
            let rows = try await registry.arr(target.app.rawValue).get("/release", query: query, timeout: 90)
            return Releases.sorted(rows.array.map(Releases.release))
        }
    }

    public func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws {
        try await call {
            _ = try await registry.arr(app.rawValue).send(
                "POST", "/release", json: ["guid": .string(guid), "indexerId": JSON(indexerID)], timeout: 90
            )
        }
    }

    public func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview] {
        try await call {
            let keys = try Renaming.keys(ref.app)
            let rows = try await registry.arr(ref.app.rawValue).get("/rename", query: [keys.item: "\(ref.id)"])
            return rows.array.map { row in
                RenamePreview(
                    existing_path: row["existingPath"].string ?? "",
                    file_id: row[keys.file].int ?? 0,
                    new_path: row["newPath"].string ?? ""
                )
            }
        }
    }

    public func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws {
        try await call {
            let keys = try Renaming.keys(ref.app)
            guard !fileIDs.isEmpty else { throw APIError.refused("nothing to rename") }
            try await registry.arr(ref.app.rawValue).send("POST", "/command", json: [
                "name": "RenameFiles", keys.item: JSON(ref.id), "files": JSON(fileIDs),
            ])
        }
    }

    public func addTorrent(_ client: TorrentClient, url: String, category: String, paused: Bool) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                var form = Dictionary(
                    uniqueKeysWithValues: TorrentAdding.qbittorrentFields(category: category, paused: paused)
                        .map { ($0.name, $0.value) }
                )
                if !url.isEmpty { form["urls"] = url }
                let response = try await registry.qbittorrent().request("POST", "/api/v2/torrents/add", form: form)
                try TorrentAdding.check(response)
            case .transmission:
                // Transmission has no categories
                var arguments: JSON = ["paused": .bool(paused)]
                if !url.isEmpty { arguments = arguments.setting("filename", .string(url)) }
                try TorrentAdding.check(try await registry.transmission().rpc("torrent-add", arguments))
            }
        }
    }

    public func addTorrentFile(_ client: TorrentClient, filename: String, data: Data, category: String, paused: Bool) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                // the fields first and the file last, as the server's upload had them
                var form = MultipartForm()
                for (name, value) in TorrentAdding.qbittorrentFields(category: category, paused: paused) {
                    form.addField(name, value: value)
                }
                form.addFile(
                    "torrents", filename: filename.isEmpty ? "upload.torrent" : filename,
                    contentType: "application/x-bittorrent", data: data
                )
                let response = try await registry.qbittorrent().request(
                    "POST", "/api/v2/torrents/add", body: form.encoded, contentType: form.contentType
                )
                try TorrentAdding.check(response)
            case .transmission:
                let result = try await registry.transmission().rpc("torrent-add", [
                    "paused": .bool(paused), "metainfo": .string(data.base64EncodedString()),
                ])
                try TorrentAdding.check(result)
            }
        }
    }

    public func qbitCategories() async throws -> [String] {
        try await call {
            try await registry.qbittorrent().get("/api/v2/torrents/categories").object.keys.sorted()
        }
    }

    public func qbitTags() async throws -> [String] {
        try await call {
            try await registry.qbittorrent().get("/api/v2/torrents/tags").array.compactMap(\.string)
        }
    }

    /// Limits in KiB/s, 0 for none. qBittorrent takes bytes and two calls;
    /// Transmission takes KiB and a flag saying whether the limit applies.
    public func setLimits(_ client: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                let qbit = try registry.qbittorrent()
                try await qbit.post("/api/v2/torrents/setDownloadLimit", form: ["hashes": id, "limit": "\(downloadKiB * 1024)"])
                try await qbit.post("/api/v2/torrents/setUploadLimit", form: ["hashes": id, "limit": "\(uploadKiB * 1024)"])
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs([id])
                try await registry.transmission().rpc("torrent-set", [
                    "ids": ids,
                    "downloadLimit": JSON(downloadKiB),
                    "downloadLimited": .bool(downloadKiB > 0),
                    "uploadLimit": JSON(uploadKiB),
                    "uploadLimited": .bool(uploadKiB > 0),
                ])
            }
        }
    }

    public func setPriority(_ client: TorrentClient, ids: [String], position: QueuePosition) async throws {
        try await call {
            switch client {
            case .qbittorrent:
                let action = switch position {
                case .top: "topPrio"
                case .bottom: "bottomPrio"
                case .up: "increasePrio"
                case .down: "decreasePrio"
                }
                try await TorrentCalls.qbittorrent(registry.qbittorrent(), action, ids)
            case .transmission:
                let ids = try TorrentCalls.transmissionIDs(ids)
                try await registry.transmission().rpc("queue-move-\(position.rawValue)", ["ids": ids])
            }
        }
    }

    public func forceStart(ids: [String]) async throws {
        try await call {
            try await TorrentCalls.qbittorrent(registry.qbittorrent(), "setForceStart", ids, ["value": "true"])
        }
    }

    public func setTags(ids: [String], tags: [String], remove: Bool) async throws {
        try await call {
            try await TorrentCalls.qbittorrent(
                registry.qbittorrent(), remove ? "removeTags" : "addTags", ids, ["tags": tags.joined(separator: ",")]
            )
        }
    }

    public func setCategory(id: String, category: String) async throws {
        try await call {
            try await TorrentCalls.qbittorrent(registry.qbittorrent(), "setCategory", [id], ["category": category])
        }
    }

    public func bulkEdit(
        _ app: LibraryApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?
    ) async throws {
        try await call {
            let editor = Bulk.editor(app)
            var payload: [String: JSON] = [editor.ids: JSON(ids)]
            if let monitored { payload["monitored"] = .bool(monitored) }
            if let qualityProfile { payload["qualityProfileId"] = JSON(qualityProfile) }
            if let tags {
                payload["tags"] = JSON(tags)
                // the arrs have to be told what to do with the tags they are handed
                payload["applyTags"] = .string((tagChange ?? .add).rawValue)
            }
            // Lidarr rewrites each artist's folder settings, which is slow
            try await registry.arr(app.arr.rawValue).send(
                "PUT", editor.path, json: .object(payload), timeout: app == .lidarr ? 30 : nil
            )
            forgetLibrary(app, authors: true)
        }
    }

    public func bulkDelete(_ app: LibraryApp, ids: [Int], deleteFiles: Bool) async throws {
        try await call {
            let editor = Bulk.editor(app)
            // Radarr names its exclusion flag differently from the other three
            let exclusion = app == .radarr ? "addImportExclusion" : "addImportListExclusion"
            try await registry.arr(app.arr.rawValue).send("DELETE", editor.path, json: [
                editor.ids: JSON(ids), "deleteFiles": .bool(deleteFiles), exclusion: false,
            ], timeout: app == .lidarr ? 60 : nil)
            forgetLibrary(app, authors: false)
        }
    }

    public func bulkSearch(_ app: LibraryApp, ids: [Int]) async throws {
        try await call {
            let arr = try registry.arr(app.arr.rawValue)
            switch app {
            case .radarr:
                try await arr.send("POST", "/command", json: ["name": "MoviesSearch", "movieIds": JSON(ids)])
            case .readarr:
                try await arr.send("POST", "/command", json: ["name": "BookSearch", "bookIds": JSON(ids)])
            // Sonarr's and Lidarr's whole-title searches take one id each
            case .sonarr:
                for id in ids {
                    try await arr.send("POST", "/command", json: ["name": "SeriesSearch", "seriesId": JSON(id)])
                }
            case .lidarr:
                // every monitored album of the artist that is missing or below cutoff
                for id in ids {
                    try await arr.send("POST", "/command", json: ["name": "ArtistSearch", "artistId": JSON(id)])
                }
            }
        }
    }

    /// Drops the cached lists a bulk change makes wrong, under the server's
    /// keys, so the next read goes to the arr. (Books and artists clearing the
    /// series map is the server's doing, kept as it was.)
    private func forgetLibrary(_ app: LibraryApp, authors: Bool) {
        var keys = [app == .radarr ? "library_map:movie" : "library_map:series"]
        if authors { keys.append("readarr:authors") }
        if app == .lidarr { keys += ["lidarr:artists", "library_map:music"] }
        cache.remove(keys)
    }
}

/// An arr's release as the search sheet lists it, from releases.py.
private enum Releases {
    static func release(_ r: JSON) -> ArrRelease {
        ArrRelease(
            age_days: r["ageHours"].double.map { $0 / 24 },
            approved: r["rejected"].bool != true,
            custom_format_score: r["customFormatScore"].int,
            custom_formats: names(r["customFormats"]),
            edition: nonEmpty(r["edition"]),
            full_season: r["fullSeason"].bool,
            guid: r["guid"].string ?? "",
            indexer: r["indexer"].string,
            indexer_id: r["indexerId"].int ?? 0,
            info_url: nonEmpty(r["infoUrl"]),
            languages: names(r["languages"]),
            leechers: r["leechers"].int,
            _protocol: nonEmpty(r["protocol"]),
            quality: r["quality"]["quality"]["name"].string,
            rejections: r["rejections"].array.compactMap(\.string),
            release_group: nonEmpty(r["releaseGroup"]),
            seeders: r["seeders"].int,
            size: r["size"].int,
            title: r["title"].string ?? ""
        )
    }

    /// Grabbable first, then the best seeded. Stable, as Python's sort is,
    /// so the arr's own order breaks ties.
    static func sorted(_ rows: [ArrRelease]) -> [ArrRelease] {
        rows.enumerated().sorted { a, b in
            let x = (a.element.approved == false ? 1 : 0, -(a.element.seeders ?? 0), a.offset)
            let y = (b.element.approved == false ? 1 : 0, -(b.element.seeders ?? 0), b.offset)
            return x < y
        }.map(\.element)
    }

    static func names(_ items: JSON) -> [String] {
        items.array.compactMap { nonEmpty($0["name"]) }
    }

    static func nonEmpty(_ value: JSON) -> String? {
        value.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Renaming is Radarr's and Sonarr's: the id a preview is asked by, and the
/// file id each row carries.
private enum Renaming {
    static func keys(_ app: ArrApp) throws -> (item: String, file: String) {
        switch app {
        case .radarr: ("movieId", "movieFileId")
        case .sonarr: ("seriesId", "episodeFileId")
        case .readarr, .lidarr: throw APIError.refused("unknown app '\(app.rawValue)'")
        }
    }
}

private enum TorrentAdding {
    /// What qBittorrent's add takes beside the torrent itself, in order.
    static func qbittorrentFields(category: String, paused: Bool) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = []
        if !category.isEmpty { fields.append(("category", category)) }
        // 5.x renamed the flag; sending both is harmless
        if paused { fields += [("stopped", "true"), ("paused", "true")] }
        return fields
    }

    /// qBittorrent refuses a torrent with a 200 and "Fails."
    static func check(_ response: ServiceResponse) throws {
        if response.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("fail") {
            throw ServiceUnavailable("qbittorrent", "qBittorrent rejected the torrent")
        }
    }

    /// Transmission answers a torrent it already has with success, and says
    /// so only by the key it puts it under.
    static func check(_ result: JSON) throws {
        if !result["torrent-duplicate"].isNull {
            throw ServiceUnavailable("transmission", "torrent already added")
        }
    }
}

/// The arrs' mass editors, and the key each takes its ids under.
private enum Bulk {
    static func editor(_ app: LibraryApp) -> (path: String, ids: String) {
        switch app {
        case .radarr: ("/movie/editor", "movieIds")
        case .sonarr: ("/series/editor", "seriesIds")
        case .readarr: ("/book/editor", "bookIds")
        case .lidarr: ("/artist/editor", "artistIds")
        }
    }
}
