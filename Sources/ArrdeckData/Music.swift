import ArrdeckAPI
import Foundation

public typealias LibraryArtist = Components.Schemas.LibraryArtistOut
public typealias LibraryAlbum = Components.Schemas.LibraryAlbumOut

/// Lidarr's artists and their albums, as much as pointing a file at an album
/// needs. There is no music library tab yet; the import sheet is the only
/// reader.
public protocol MusicLibraryAPI: Sendable {
    /// Every artist, by Lidarr's own sort name.
    func libraryArtists() async throws -> [LibraryArtist]
    /// One artist's albums, EPs and singles, newest first.
    func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum]
}

extension LiveAPI: MusicLibraryAPI {
    public func libraryArtists() async throws -> [LibraryArtist] {
        try await call {
            switch try await client.library_artists_api_v1_library_artists_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum] {
        try await call {
            switch try await client.artist_albums_api_v1_library_artists__artist_id__albums_get(
                path: .init(artist_id: artistID)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension ImportTargetSearch {
    /// Artists in the server's order (Lidarr's sort name), filtered by name.
    public static func artists(_ artists: [LibraryArtist], query: String) -> [LibraryArtist] {
        Array(artists.filter { matches(query, $0.name) }.prefix(limit))
    }

    /// An artist's albums in the server's order, newest first, filtered by title.
    public static func albums(_ albums: [LibraryAlbum], query: String) -> [LibraryAlbum] {
        albums.filter { matches(query, $0.title) }
    }

    /// "Boards of Canada — Geogaddi", as the file row shows the pick.
    public static func albumLabel(artist: String, album: LibraryAlbum) -> String {
        let title = album.title ?? ""
        return artist.isEmpty ? title : "\(artist) — \(title)"
    }
}
