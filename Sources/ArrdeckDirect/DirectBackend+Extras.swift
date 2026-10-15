import ArrdeckData
import Foundation

extension DirectBackend: ExtrasAPI {
    public func releases(_ target: ReleaseTarget) async throws -> [ArrRelease] {
        throw APIError.needsServer
    }

    public func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws {
        throw APIError.needsServer
    }

    public func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview] {
        throw APIError.needsServer
    }

    public func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws {
        throw APIError.needsServer
    }

    public func addTorrent(_ client: TorrentClient, url: String, category: String, paused: Bool) async throws {
        throw APIError.needsServer
    }

    public func addTorrentFile(_ client: TorrentClient, filename: String, data: Data, category: String, paused: Bool) async throws {
        throw APIError.needsServer
    }

    public func qbitCategories() async throws -> [String] {
        throw APIError.needsServer
    }

    public func qbitTags() async throws -> [String] {
        throw APIError.needsServer
    }

    public func setLimits(_ client: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws {
        throw APIError.needsServer
    }

    public func setPriority(_ client: TorrentClient, ids: [String], position: QueuePosition) async throws {
        throw APIError.needsServer
    }

    public func forceStart(ids: [String]) async throws {
        throw APIError.needsServer
    }

    public func setTags(ids: [String], tags: [String], remove: Bool) async throws {
        throw APIError.needsServer
    }

    public func setCategory(id: String, category: String) async throws {
        throw APIError.needsServer
    }

    public func bulkEdit(_ app: LibraryApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?) async throws {
        throw APIError.needsServer
    }

    public func bulkDelete(_ app: LibraryApp, ids: [Int], deleteFiles: Bool) async throws {
        throw APIError.needsServer
    }

    public func bulkSearch(_ app: LibraryApp, ids: [Int]) async throws {
        throw APIError.needsServer
    }
}
