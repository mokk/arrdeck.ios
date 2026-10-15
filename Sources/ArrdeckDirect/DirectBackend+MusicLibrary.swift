import ArrdeckData
import Foundation

/// Lidarr's library: artists and their albums, an album's tracks and files,
/// and editing them. Ported from the server's music.py; the rows are in
/// `Direct+CatalogMusic.swift`, shared with the Add screen's music search.
extension DirectBackend: MusicLibraryAPI {
    /// Every artist, by Lidarr's own sort name.
    public func libraryArtists() async throws -> [LibraryArtist] {
        try await call {
            try await catalogArtists(try registry.arr("lidarr"))
                .compactMap { CatalogMusic.artist($0, poster: lidarrImage($0)) }
                .sorted { ($0.sort_name.nonBlank ?? $0.name ?? "").lowercased() < ($1.sort_name.nonBlank ?? $1.name ?? "").lowercased() }
        }
    }

    public func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum] {
        try await call {
            let albums = try await registry.arr("lidarr").get("/album", query: ["artistId": String(artistID)]).array
            return CatalogMusic.newestFirst(albums.compactMap { CatalogMusic.album($0) })
        }
    }

    /// The artist with every album Lidarr knows for them, monitored or not:
    /// this is where an album gets monitored.
    public func artistDetail(_ id: Int) async throws -> ArtistDetail {
        try await call {
            let lidarr = try registry.arr("lidarr")
            async let albums = lidarr.get("/album", query: ["artistId": String(id)]).array
            let artist = try await lidarr.get("/artist/\(id)")
            guard let row = CatalogMusic.artist(artist, poster: lidarrImage(artist, size: CatalogMusic.detailSize)) else {
                throw APIError.refused("artist not found")
            }
            let name = row.name ?? ""
            return ArtistDetail(
                added: row.added, album_count: row.album_count,
                albums: CatalogMusic.newestFirst(try await albums.compactMap { CatalogMusic.album($0, artistName: name) }),
                artist_type: Catalog.text(artist["artistType"]), disambiguation: row.disambiguation,
                fanart: lidarrImage(artist, kind: "fanart"), genres: row.genres, id: row.id,
                links: CatalogMusic.links(artist), metadata_profile_id: row.metadata_profile_id,
                monitor_new_items: row.monitor_new_items, monitored: row.monitored, name: row.name,
                overview: Catalog.text(artist["overview"]), path: artist["path"].string, poster: row.poster,
                quality_profile_id: row.quality_profile_id, rating: row.rating, ratings: CatalogMusic.ratings(artist),
                root_folder_path: artist["rootFolderPath"].string, size_on_disk: row.size_on_disk, slug: row.slug,
                sort_name: row.sort_name, status: row.status, tags: row.tags, track_count: row.track_count,
                track_file_count: row.track_file_count
            )
        }
    }

    /// Monitoring, profiles, folder and tags. Lidarr takes the whole artist
    /// back, so it is read, changed and returned; only what changed is set.
    public func updateArtist(_ id: Int, _ changes: ArtistChanges) async throws {
        try await call {
            let lidarr = try registry.arr("lidarr")
            var artist = try await lidarr.get("/artist/\(id)")
            if let monitored = changes.monitored { artist = artist.setting("monitored", .bool(monitored)) }
            if let newAlbums = changes.monitorNewItems { artist = artist.setting("monitorNewItems", .string(newAlbums.rawValue)) }
            if let profile = changes.qualityProfile { artist = artist.setting("qualityProfileId", JSON(profile)) }
            if let profile = changes.metadataProfile { artist = artist.setting("metadataProfileId", JSON(profile)) }
            if let tags = changes.tags { artist = artist.setting("tags", JSON(tags)) }
            var move = false
            if let raw = changes.path {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/") else { throw APIError.refused("path must be absolute") }
                move = changes.moveFiles && path != artist["path"].string
                artist = artist.setting("path", .string(path))
            }
            try await lidarr.send("PUT", "/artist/\(id)", query: ["moveFiles": move ? "true" : "false"], json: artist, timeout: 30)
            catalogForgetArtists()
        }
    }

    public func refreshArtist(_ id: Int) async throws {
        try await call {
            try await registry.arr("lidarr").send("POST", "/command", json: ["name": "RefreshArtist", "artistId": JSON(id)])
            catalogForgetArtists()
        }
    }

    public func albumDetail(_ id: Int) async throws -> AlbumDetail {
        try await call {
            let lidarr = try registry.arr("lidarr")
            let query = ["albumId": String(id)]
            async let tracks = lidarr.get("/track", query: query).array
            // without files the tracks still say what is there; history is decoration
            async let files = try? lidarr.get("/trackfile", query: query).array
            async let history = try? lidarr.get("/history", query: [
                "pageSize": "100", "page": "1", "sortKey": "date", "sortDirection": "descending", "albumId": String(id),
            ])["records"].array
            let album = try await lidarr.get("/album/\(id)")
            let trackList = try await tracks
            let artist = album["artist"]
            let stats = album["statistics"]
            let release = CatalogMusic.chosenRelease(album)
            let label = release["label"].array.compactMap(\.string).joined(separator: ", ")
            let releaseBits = [Catalog.text(release["format"]), label.isEmpty ? nil : label].compactMap { $0 }
            let trackCount = CatalogMusic.trackCount(stats)
            return AlbumDetail(
                album_type: album["albumType"].string, artist: artist["artistName"].string,
                artist_id: album["artistId"].int, artist_slug: artist["foreignArtistId"].string,
                disambiguation: Catalog.text(album["disambiguation"]), duration: CatalogMusic.seconds(album["duration"]),
                genres: album["genres"].array.compactMap(\.string), history: CatalogMusic.history(await history ?? []),
                id: album["id"].int ?? id, links: CatalogMusic.links(album),
                media: release["media"].array.map { medium in
                    AlbumMedium(
                        format: Catalog.text(medium["mediumFormat"]), name: Catalog.text(medium["mediumName"]),
                        number: medium["mediumNumber"].int ?? 0
                    )
                },
                monitored: album["monitored"].bool ?? false, overview: Catalog.text(album["overview"]),
                poster: Artwork.musicCover(album["images"]), quality_profile_id: artist["qualityProfileId"].int,
                ratings: CatalogMusic.ratings(album), release: releaseBits.isEmpty ? nil : releaseBits.joined(separator: " · "),
                release_date: album["releaseDate"].string, secondary_types: album["secondaryTypes"].array.compactMap(\.string),
                size_on_disk: stats["sizeOnDisk"].int ?? 0, slug: album["foreignAlbumId"].string,
                title: album["title"].string ?? "", track_count: trackCount == 0 ? trackList.count : trackCount,
                track_file_count: stats["trackFileCount"].int ?? 0,
                tracks: CatalogMusic.tracks(trackList, files: await files ?? []),
                year: DirectBackend.year(album["releaseDate"])
            )
        }
    }

    /// From disk; the album stays, so a monitored one is searched for again.
    /// A single file must belong to the album.
    public func deleteAlbumFiles(album: Int, file: Int?) async throws {
        try await call {
            let lidarr = try registry.arr("lidarr")
            let files = try await lidarr.get("/trackfile", query: ["albumId": String(album)]).array.compactMap { $0["id"].int }
            let doomed: [Int]
            if let file {
                guard files.contains(file) else { throw APIError.refused("no such file on this album") }
                doomed = [file]
            } else {
                doomed = files
            }
            if !doomed.isEmpty {
                try await lidarr.send("DELETE", "/trackfile/bulk", json: ["trackFileIds": JSON(doomed)])
            }
            catalogForgetArtists()
        }
    }
}

private extension Optional where Wrapped == String {
    /// The sort name when Lidarr has one; an empty one is none.
    var nonBlank: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
