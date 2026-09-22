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

extension LiveAPI: DownloadsAPI {
    public func torrents(_ query: TorrentQuery) async throws -> [TorrentClient: Block<TorrentGroup>] {
        try await call {
            switch try await client.torrents_api_v1_torrents_get(query: .init(
                q: query.text.isEmpty ? nil : query.text,
                state: query.state,
                sort: query.sort.rawValue,
                dir: query.descending ? "desc" : "asc",
                limit: query.limit
            )) {
            case let .ok(ok):
                let body = try ok.body.json
                return [.qbittorrent: Block(body.qbittorrent), .transmission: Block(body.transmission)]
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func speedLimit() async throws -> [TorrentClient: Bool] {
        try await call {
            switch try await client.speed_limit_api_v1_torrents_speed_limit_get() {
            case let .ok(ok):
                let body = try ok.body.json
                return [.qbittorrent: body.qbittorrent ?? false, .transmission: body.transmission ?? false]
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setSpeedLimit(_ torrentClient: TorrentClient, enabled: Bool) async throws {
        try await call {
            switch try await client.set_speed_limit_api_v1_torrents__client__speed_limit_post(
                path: .init(client: torrentClient.rawValue), body: .json(.init(enabled: enabled))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func pause(_ torrentClient: TorrentClient, ids: [String]) async throws {
        try await call {
            switch torrentClient {
            case .qbittorrent:
                switch try await client.qbit_pause_api_v1_torrents_qbittorrent_pause_post(body: .json(.init(ids: ids))) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .transmission:
                switch try await client.tm_pause_api_v1_torrents_transmission_pause_post(body: .json(.init(ids: ids))) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func resume(_ torrentClient: TorrentClient, ids: [String]) async throws {
        try await call {
            switch torrentClient {
            case .qbittorrent:
                switch try await client.qbit_resume_api_v1_torrents_qbittorrent_resume_post(body: .json(.init(ids: ids))) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .transmission:
                switch try await client.tm_resume_api_v1_torrents_transmission_resume_post(body: .json(.init(ids: ids))) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func delete(_ torrentClient: TorrentClient, ids: [String], deleteData: Bool) async throws {
        try await call {
            let body = Components.Schemas.TorrentDeleteIn(delete_data: deleteData, ids: ids)
            switch torrentClient {
            case .qbittorrent:
                switch try await client.qbit_delete_api_v1_torrents_qbittorrent_delete_post(body: .json(body)) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .transmission:
                switch try await client.tm_delete_api_v1_torrents_transmission_delete_post(body: .json(body)) {
                case .noContent: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func recheck(_ torrentClient: TorrentClient, ids: [String]) async throws {
        try await call {
            switch try await client.torrent_recheck_api_v1_torrents__client__recheck_post(
                path: .init(client: torrentClient.rawValue), body: .json(.init(ids: ids))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func details(_ torrentClient: TorrentClient, id: String) async throws -> TorrentDetails {
        try await call {
            switch try await client.torrent_details_api_v1_torrents__client___torrent_id__details_get(
                path: .init(client: torrentClient.rawValue, torrent_id: id)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func removeFromQueue(app: ArrApp, id: Int) async throws {
        try await call {
            switch try await client.remove_queue_item_api_v1_queue__app___item_id__delete(
                path: .init(app: app.rawValue, item_id: id), query: .init(remove_from_client: true)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}
