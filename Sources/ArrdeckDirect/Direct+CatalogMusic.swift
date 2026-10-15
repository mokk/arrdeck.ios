import ArrdeckData
import Foundation

/// Lidarr's artists and albums as the Music tab and the Add screen show
/// them, ported from the server's music.py and musicsearch.py. Lidarr hangs
/// albums off artists the way Readarr hangs books off authors: the profiles
/// are the artist's, an album has its own monitored flag.
enum CatalogMusic {
    /// A Music tab card: Lidarr's 250 px copy, a twentieth of the original.
    static let gridSize = "250"
    static let detailSize = "500"

    static let artistsKey = "lidarr:artists"
    static let libraryKey = "library_map:music"

    /// Lidarr's statistics count tracks two ways; the total, when it has one.
    static func trackCount(_ stats: JSON) -> Int {
        stats["totalTrackCount"].nonZero ?? stats["trackCount"].int ?? 0
    }

    static func artist(_ artist: JSON, poster: String?) -> LibraryArtist? {
        guard let id = artist["id"].int else { return nil }
        let stats = artist["statistics"]
        return LibraryArtist(
            added: artist["added"].date, album_count: stats["albumCount"].int ?? 0,
            disambiguation: artist["disambiguation"].nonEmpty, genres: artist["genres"].array.compactMap(\.string),
            id: id, metadata_profile_id: artist["metadataProfileId"].int,
            monitor_new_items: artist["monitorNewItems"].string, monitored: artist["monitored"].bool ?? false,
            name: artist["artistName"].string ?? "", poster: poster, quality_profile_id: artist["qualityProfileId"].int,
            rating: Ratings.music(artist), size_on_disk: stats["sizeOnDisk"].int ?? 0,
            // the MusicBrainz id is Lidarr's own URL segment: /artist/<id>
            slug: artist["foreignArtistId"].string, sort_name: artist["sortName"].string,
            status: artist["status"].string, tags: artist["tags"].array.compactMap(\.int),
            track_count: trackCount(stats), track_file_count: stats["trackFileCount"].int ?? 0
        )
    }

    /// `artistName` stands in for an album that does not carry its artist,
    /// as an artist's own album list does not.
    static func album(_ album: JSON, artistName: String? = nil) -> LibraryAlbum? {
        guard let id = album["id"].int else { return nil }
        let stats = album["statistics"]
        return LibraryAlbum(
            album_type: album["albumType"].string,
            artist: album["artist"]["artistName"].nonEmpty ?? artistName, artist_id: album["artistId"].int,
            id: id, monitored: album["monitored"].bool ?? false, poster: Artwork.musicCover(album["images"]),
            rating: Ratings.music(album), release_date: album["releaseDate"].string,
            secondary_types: album["secondaryTypes"].array.compactMap(\.string),
            size_on_disk: stats["sizeOnDisk"].int ?? 0, title: album["title"].string ?? "",
            track_count: trackCount(stats), track_file_count: stats["trackFileCount"].int ?? 0,
            year: DirectBackend.year(album["releaseDate"])
        )
    }

    /// Newest first, by the date as Lidarr writes it.
    static func newestFirst(_ albums: [LibraryAlbum]) -> [LibraryAlbum] {
        albums.sorted { ($0.release_date ?? "") > ($1.release_date ?? "") }
    }

    /// The single score as the chip the film and show pages show: Lidarr
    /// takes it from MusicBrainz's community ratings.
    static func ratings(_ item: JSON) -> [Rating] {
        guard let value = Ratings.music(item) else { return [] }
        let votes = item["ratings"]["votes"].nonZero
        return [Rating(source: "musicbrainz", value: value, votes: votes)]
    }

    /// One link per site: an artist lists Apple Music four times.
    static func links(_ item: JSON) -> [MusicLink] {
        var seen: Set<String> = []
        return item["links"].array.compactMap { link in
            let name = (link["name"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link["url"].string ?? ""
            guard !name.isEmpty, url.hasPrefix("http://") || url.hasPrefix("https://"), !seen.contains(name) else {
                return nil
            }
            seen.insert(name)
            return MusicLink(name: name, url: url)
        }
    }

    /// The release an album's files are matched to: the monitored one, else
    /// the first.
    static func chosenRelease(_ album: JSON) -> JSON {
        let releases = album["releases"].array
        return releases.first { $0["monitored"].bool == true } ?? releases.first ?? .null
    }

    /// Milliseconds to whole seconds, rounding as Python's `round` does.
    static func seconds(_ milliseconds: JSON) -> Int? {
        guard let value = milliseconds.double, value != 0 else { return nil }
        return Int((value / 1000).rounded(.toNearestOrEven))
    }

    static func tracks(_ tracks: [JSON], files: [JSON]) -> [AlbumTrack] {
        let byID = files.byID
        return tracks.compactMap { track -> AlbumTrack? in
            guard let id = track["id"].int else { return nil }
            let file = track["trackFileId"].nonZero.flatMap { byID[$0] }
            let number = track["trackNumber"].nonEmpty ?? track["trackNumber"].nonZero.map(String.init)
            return AlbumTrack(
                absolute: track["absoluteTrackNumber"].int ?? 0, duration: seconds(track["duration"]),
                file_id: file?["id"].int, has_file: track["hasFile"].bool ?? false, id: id,
                medium: track["mediumNumber"].nonZero ?? 1, number: number,
                quality: file?["quality"]["quality"]["name"].string, size: file?["size"].int, title: track["title"].string
            )
        }
        .sorted { ($0.medium ?? 1, $0.absolute ?? 0) < ($1.medium ?? 1, $1.absolute ?? 0) }
    }

    /// What the arrs record, in the words the history rows use.
    static let eventLabels = [
        "grabbed": "fetched", "downloadFolderImported": "imported", "downloadFailed": "failed",
        "downloadIgnored": "ignored", "movieFileDeleted": "deleted", "episodeFileDeleted": "deleted",
        "movieFileRenamed": "renamed", "episodeFileRenamed": "renamed",
        "bookFileImported": "imported", "bookImportIncomplete": "incomplete", "bookFileDeleted": "deleted",
        "bookFileRenamed": "renamed", "bookFileRetagged": "renamed",
        "trackFileImported": "imported", "downloadImported": "imported", "artistFolderImported": "imported",
        "albumImportIncomplete": "incomplete", "trackFileDeleted": "deleted", "trackFileRenamed": "renamed",
        "trackFileRetagged": "renamed",
    ]

    /// An album's history as events. Lidarr records an import per track, so
    /// one download comes down to one event of each kind.
    static func history(_ records: [JSON], limit: Int = 12) -> [HistoryEvent] {
        var seen: Set<String> = []
        var out: [HistoryEvent] = []
        for record in records {
            let raw = record["eventType"].string ?? ""
            let label = eventLabels[raw] ?? raw
            let date = record["date"].string ?? ""
            let key = label + "\u{1F}" + (record["downloadId"].nonEmpty ?? String(date.prefix(16)))
            guard seen.insert(key).inserted else { continue }
            out.append(HistoryEvent(date: date, _type: label))
        }
        return Array(out.prefix(limit))
    }

    /// One entry of Lidarr's combined search: an artist or an album.
    static func result(_ entry: JSON, held: [String: Catalog.Held]) -> SearchResult? {
        let artist = entry["artist"]
        if !artist.object.isEmpty {
            let foreign = artist["foreignArtistId"].string
            let known = held[foreign ?? ""]
            // Lidarr's search hands back a library artist without artwork
            let poster = Artwork.musicCover(artist["images"], kinds: ["poster"])
                ?? artist["remotePoster"].nonEmpty.map { Artwork.normalise($0) } ?? known?.poster
            let result = SearchResult(
                foreign_id: foreign, kind: "artist", overview: artist["overview"].nonEmpty, poster: poster,
                remote_id: 0, title: artist["artistName"].string ?? ""
            )
            return Catalog.result(result, held: known)
        }
        let album = entry["album"]
        guard !album.object.isEmpty else { return nil }
        let foreign = album["foreignAlbumId"].string
        let result = SearchResult(
            album_type: album["albumType"].nonEmpty, artist: album["artist"]["artistName"].string,
            foreign_id: foreign, kind: "album", overview: album["overview"].nonEmpty,
            poster: Artwork.musicCover(album["images"]) ?? album["remoteCover"].nonEmpty.map { Artwork.normalise($0) },
            remote_id: 0, title: album["title"].string ?? "", year: DirectBackend.year(album["releaseDate"])
        )
        return Catalog.result(result, held: held[foreign ?? ""])
    }

    /// A looked-up artist made ready to add: the settings over the lookup,
    /// tags at least empty, and the add options Lidarr applies once they are in.
    static func newArtist(
        _ artist: JSON, qualityProfile: Int, metadataProfile: Int?, rootFolder: String, monitorNewItems: String,
        addOptions: JSON
    ) -> JSON {
        var fields = artist.object
        fields["qualityProfileId"] = JSON(qualityProfile)
        fields["metadataProfileId"] = JSON(metadataProfile)
        fields["rootFolderPath"] = .string(rootFolder)
        fields["monitored"] = true
        fields["monitorNewItems"] = .string(monitorNewItems)
        if fields["tags"]?.array.isEmpty ?? true { fields["tags"] = [] }
        fields["addOptions"] = addOptions
        return .object(fields)
    }
}

extension DirectBackend {
    /// Every artist Lidarr tracks, kept a minute: the Music tab, the import
    /// picker and the search badges all read it.
    func catalogArtists(_ lidarr: KeyedClient) async throws -> [JSON] {
        try await cached(CatalogMusic.artistsKey, ttl: 60) { try await lidarr.get("/artist").array }
    }

    /// Artists and albums from Lidarr's metadata server, best match first.
    func catalogMusicSearch(_ query: String) async throws -> [SearchResult] {
        let lidarr = try registry.arr("lidarr")
        async let library = heldMusic(lidarr)
        // a fresh term sends Lidarr to its metadata server
        let entries = try await lidarr.get("/search", query: ["term": query], timeout: 90).array
        let held = try await library
        return Array(entries.compactMap { CatalogMusic.result($0, held: held) }.prefix(30))
    }

    /// An artist with the albums their metadata profile allows, monitored as
    /// `monitor` says (Lidarr's own choices: all, future, missing, existing,
    /// latest, first, none). The lookup is repeated by MusicBrainz id because
    /// Lidarr wants the whole resource back.
    func catalogAddArtist(
        _ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, monitor: String
    ) async throws {
        guard let foreign = result.foreign_id else { throw APIError.unexpectedStatus(422) }
        let lidarr = try registry.arr("lidarr")
        let found = try await lidarr.get("/artist/lookup", query: ["term": "lidarr:\(foreign)"], timeout: 90).array
        guard let artist = found.first(where: { $0["foreignArtistId"].string == foreign }) else {
            throw APIError.refused("Lidarr no longer finds that artist")
        }
        let payload = CatalogMusic.newArtist(
            artist, qualityProfile: qualityProfile,
            metadataProfile: try await defaultMetadataProfile(lidarr, metadataProfile), rootFolder: rootFolder,
            monitorNewItems: "all",
            // Lidarr sets the artist's own flag from addOptions.monitored once
            // added; monitoring nothing leaves nothing to search for yet
            addOptions: ["monitor": .string(monitor), "monitored": true, "searchForMissingAlbums": .bool(monitor != "none")]
        )
        // adding pulls the whole discography from the metadata server first
        try await lidarr.send("POST", "/artist", json: payload, timeout: 90)
        forgetArtists()
    }

    /// One album. When Lidarr does not have its artist they come too, the
    /// way its own Add Album does: with these profiles and folder, only this
    /// album monitored, and later albums left alone.
    func catalogAddAlbum(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?) async throws {
        guard let foreign = result.foreign_id else { throw APIError.unexpectedStatus(422) }
        let lidarr = try registry.arr("lidarr")
        let found = try await lidarr.get("/album/lookup", query: ["term": "lidarr:\(foreign)"], timeout: 90).array
        guard let album = found.first(where: { $0["foreignAlbumId"].string == foreign }) else {
            throw APIError.refused("Lidarr no longer finds that album")
        }
        var artist = album["artist"]
        if (artist["id"].int ?? 0) == 0 {
            artist = CatalogMusic.newArtist(
                artist, qualityProfile: qualityProfile,
                metadataProfile: try await defaultMetadataProfile(lidarr, metadataProfile), rootFolder: rootFolder,
                monitorNewItems: "none",
                // albumsToMonitor wins over `monitor` for the albums, so only
                // this one is monitored; "none" would leave the artist
                // unmonitored too, and their albums never searched for
                addOptions: [
                    "monitor": "all", "albumsToMonitor": [.string(foreign)], "monitored": true,
                    "searchForMissingAlbums": false,
                ]
            )
        }
        let payload = album
            .setting("artist", artist)
            .setting("monitored", true)
            .setting("addOptions", ["searchForNewAlbum": true])
        try await lidarr.send("POST", "/album", json: payload, timeout: 90)
        forgetArtists()
    }

    private func defaultMetadataProfile(_ lidarr: KeyedClient, _ chosen: Int?) async throws -> Int? {
        if let chosen { return chosen }
        return try await lidarr.get("/metadataprofile").array.first?["id"].int
    }

    /// MusicBrainz id to what the library holds, artists and albums alike
    /// (the ids never collide), for the in-library badge on search results.
    private func heldMusic(_ lidarr: KeyedClient) async throws -> [String: Catalog.Held] {
        try await cached(CatalogMusic.libraryKey, ttl: 60) {
            async let albums = lidarr.get("/album").array
            let artists = try await catalogArtists(lidarr)
            var out: [String: Catalog.Held] = [:]
            for artist in artists {
                guard let foreign = artist["foreignArtistId"].nonEmpty, let id = artist["id"].int else { continue }
                out[foreign] = Catalog.Held(
                    libraryID: id, monitored: artist["monitored"].bool ?? false,
                    qualityProfile: artist["qualityProfileId"].int,
                    hasFile: (artist["statistics"]["trackFileCount"].int ?? 0) > 0, poster: lidarrImage(artist)
                )
            }
            for album in try await albums {
                guard let foreign = album["foreignAlbumId"].nonEmpty, let id = album["id"].int else { continue }
                out[foreign] = Catalog.Held(
                    libraryID: id, monitored: album["monitored"].bool ?? false, qualityProfile: nil,
                    hasFile: (album["statistics"]["trackFileCount"].int ?? 0) > 0
                )
            }
            return out
        }
    }
}
