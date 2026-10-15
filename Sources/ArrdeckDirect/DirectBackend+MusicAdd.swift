import ArrdeckData
import Foundation

/// Adding an artist with a choice of which albums to monitor, or a single
/// album: the catalogue's own adds (`Direct+CatalogMusic.swift`), ported
/// from the server's musicsearch.py.
extension DirectBackend: MusicAddAPI {
    public func addArtist(
        _ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, monitor: ArtistMonitor
    ) async throws {
        try await call {
            // the choices are Lidarr's own words, so they go through as they are
            try await catalogAddArtist(
                result, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadataProfile,
                monitor: monitor.rawValue
            )
        }
    }

    public func addAlbum(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?) async throws {
        try await call {
            try await catalogAddAlbum(
                result, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadataProfile
            )
        }
    }
}
