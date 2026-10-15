import ArrdeckData
import Foundation

extension DirectBackend: MusicLibraryAPI {
    public func libraryArtists() async throws -> [LibraryArtist] {
        throw APIError.needsServer
    }

    public func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum] {
        throw APIError.needsServer
    }

    public func artistDetail(_ id: Int) async throws -> ArtistDetail {
        throw APIError.needsServer
    }

    public func updateArtist(_ id: Int, _ changes: ArtistChanges) async throws {
        throw APIError.needsServer
    }

    public func refreshArtist(_ id: Int) async throws {
        throw APIError.needsServer
    }

    public func albumDetail(_ id: Int) async throws -> AlbumDetail {
        throw APIError.needsServer
    }

    public func deleteAlbumFiles(album: Int, file: Int?) async throws {
        throw APIError.needsServer
    }
}
