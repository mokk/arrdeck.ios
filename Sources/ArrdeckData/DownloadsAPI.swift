import ArrdeckAPI
import Foundation
import OpenAPIRuntime

/// What the Downloads screen asks of the backend.
public protocol DownloadsAPI: Sendable {
    func torrents(_ query: TorrentQuery) async throws -> [TorrentClient: Block<TorrentGroup>]
    func speedLimit() async throws -> [TorrentClient: Bool]
    func setSpeedLimit(_ client: TorrentClient, enabled: Bool) async throws
    func pause(_ client: TorrentClient, ids: [String]) async throws
    func resume(_ client: TorrentClient, ids: [String]) async throws
    func delete(_ client: TorrentClient, ids: [String], deleteData: Bool) async throws
    func recheck(_ client: TorrentClient, ids: [String]) async throws
    func details(_ client: TorrentClient, id: String) async throws -> TorrentDetails

    func queue() async throws -> [ArrApp: Block<[QueueItem]>]
    func forceImport(app: ArrApp, id: Int) async throws
    func blocklistRetry(app: ArrApp, id: Int) async throws
    func removeFromQueue(app: ArrApp, id: Int) async throws
}
