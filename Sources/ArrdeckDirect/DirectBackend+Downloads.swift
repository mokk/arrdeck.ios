import ArrdeckData
import Foundation

extension DirectBackend: DownloadsAPI {
    public func torrents(_ query: TorrentQuery) async throws -> [TorrentClient: Block<TorrentGroup>] {
        throw APIError.needsServer
    }

    public func speedLimit() async throws -> [TorrentClient: Bool] {
        throw APIError.needsServer
    }

    public func setSpeedLimit(_ client: TorrentClient, enabled: Bool) async throws {
        throw APIError.needsServer
    }

    public func pause(_ client: TorrentClient, ids: [String]) async throws {
        throw APIError.needsServer
    }

    public func resume(_ client: TorrentClient, ids: [String]) async throws {
        throw APIError.needsServer
    }

    public func delete(_ client: TorrentClient, ids: [String], deleteData: Bool) async throws {
        throw APIError.needsServer
    }

    public func recheck(_ client: TorrentClient, ids: [String]) async throws {
        throw APIError.needsServer
    }

    public func details(_ client: TorrentClient, id: String) async throws -> TorrentDetails {
        throw APIError.needsServer
    }

    public func removeFromQueue(app: ArrApp, id: Int) async throws {
        throw APIError.needsServer
    }
}
