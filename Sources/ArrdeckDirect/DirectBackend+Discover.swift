import ArrdeckData
import Foundation

extension DirectBackend: DiscoverAPI {
    public func search(_ kind: MediaKind, query: String) async throws -> [SearchResult] {
        throw APIError.needsServer
    }

    public func searchReleases(_ query: String) async throws -> [Release] {
        throw APIError.needsServer
    }

    public func discover(_ kind: MediaKind) async throws -> [SearchResult] {
        throw APIError.needsServer
    }

    public func grab(guid: String, indexerID: Int) async throws {
        throw APIError.needsServer
    }

    public func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, edition: String?) async throws {
        throw APIError.needsServer
    }

    public func collections() async throws -> [Collection] {
        throw APIError.needsServer
    }

    public func collectionDetail(_ id: Int) async throws -> CollectionDetail {
        throw APIError.needsServer
    }

    public func setCollectionMonitored(_ id: Int, _ monitored: Bool) async throws {
        throw APIError.needsServer
    }

    public func popular(hours: Int, limit: Int) async throws -> Block<PopularSnapshot> {
        throw APIError.needsServer
    }
}
