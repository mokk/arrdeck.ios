import ArrdeckAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public enum RequestAction: String, Sendable {
    case approve, decline
}

public enum SubtitleKind: String, Sendable {
    case movie, episode
}

/// Why a call to arrdeck itself failed. Not to be confused with a Block's
/// offline reason, which arrdeck reports about a service behind it.
public enum APIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The session cookie is gone or was revoked. The next move is the
    /// pairing screen, not a retry.
    case unauthorized
    case unexpectedStatus(Int)
    case transport(String)

    public var description: String {
        switch self {
        case .unauthorized: "signed out"
        case let .unexpectedStatus(code): "HTTP \(code)"
        case let .transport(reason): reason
        }
    }

    static func status(_ code: Int) -> APIError {
        code == 401 ? .unauthorized : .unexpectedStatus(code)
    }
}

/// Everything the dashboard asks of the backend, in domain terms. The model
/// depends on this rather than on the generated client so tests can feed it
/// canned answers; `LiveAPI` is the one real implementation.
public protocol DashboardAPI: Sendable {
    func services() async throws -> [ServiceInfo]
    func playSessions() async throws -> Block<[PlaySession]>
    func health() async throws -> Block<[HealthWarning]>
    func pendingRequests() async throws -> Block<[MediaRequest]>
    func recent() async throws -> [RecentItem]
    func torrentSummary() async throws -> [TorrentClient: Block<TorrentSummary>]
    func queue() async throws -> [ArrApp: Block<[QueueItem]>]
    func calendar() async throws -> [ArrApp: Block<[CalendarItem]>]
    func diskSpace() async throws -> Block<[DiskSpace]>
    func vpn() async throws -> Block<VpnStatus>
    func subtitles() async throws -> Block<Subtitles>
    func history() async throws -> [ArrApp: Block<[HistoryItem]>]
    func indexerStats() async throws -> Block<IndexerStats>
    func statsHistory(days: Int) async throws -> [StatsSample]

    func act(on requestID: Int, _ action: RequestAction) async throws
    func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws
    func forceImport(app: ArrApp, id: Int) async throws
    func blocklistRetry(app: ArrApp, id: Int) async throws
}

/// The generated client, with each operation's output enum folded into a
/// value or an `APIError`.
public struct LiveAPI: DashboardAPI {
    let client: ArrdeckAPI.Client

    public init(client: ArrdeckAPI.Client) {
        self.client = client
    }

    /// A client whose requests carry the session cookie pairing stored in
    /// `HTTPCookieStorage.shared`; on a LAN profile there is none and the
    /// backend answers anyway.
    public init(baseURL: URL, cookies: HTTPCookieStorage? = .shared, timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = cookies
        let transport = OpenAPIURLSession.URLSessionTransport(
            configuration: .init(session: URLSession(configuration: config))
        )
        self.init(client: ArrdeckAPI.Client(serverURL: baseURL, transport: transport))
    }

    public func services() async throws -> [ServiceInfo] {
        try await call {
            switch try await client.services_api_v1_services_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func playSessions() async throws -> Block<[PlaySession]> {
        try await call {
            switch try await client.play_sessions_api_v1_sessions_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func health() async throws -> Block<[HealthWarning]> {
        try await call {
            switch try await client.health_api_v1_health_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func pendingRequests() async throws -> Block<[MediaRequest]> {
        try await call {
            switch try await client.media_requests_api_v1_requests_get(query: .init(filter: "pending")) {
            case let .ok(ok): Block(try ok.body.json)
            case let .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func recent() async throws -> [RecentItem] {
        try await call {
            switch try await client.recent_api_v1_dashboard_recent_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func torrentSummary() async throws -> [TorrentClient: Block<TorrentSummary>] {
        try await call {
            switch try await client.torrents_summary_api_v1_torrents_summary_get() {
            case let .ok(ok):
                let body = try ok.body.json
                return [.qbittorrent: Block(body.qbittorrent), .transmission: Block(body.transmission)]
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func queue() async throws -> [ArrApp: Block<[QueueItem]>] {
        try await call {
            switch try await client.queue_api_v1_queue_get() {
            case let .ok(ok):
                let body = try ok.body.json
                var out: [ArrApp: Block<[QueueItem]>] = [.radarr: Block(body.radarr), .sonarr: Block(body.sonarr)]
                if let readarr = body.readarr { out[.readarr] = Block(readarr) }
                return out
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func calendar() async throws -> [ArrApp: Block<[CalendarItem]>] {
        try await call {
            switch try await client.calendar_api_v1_calendar_get() {
            case let .ok(ok):
                let body = try ok.body.json
                var out: [ArrApp: Block<[CalendarItem]>] = [.radarr: Block(body.radarr), .sonarr: Block(body.sonarr)]
                if let readarr = body.readarr { out[.readarr] = Block(readarr) }
                return out
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func diskSpace() async throws -> Block<[DiskSpace]> {
        try await call {
            switch try await client.diskspace_api_v1_diskspace_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func vpn() async throws -> Block<VpnStatus> {
        try await call {
            switch try await client.vpn_status_api_v1_vpn_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func subtitles() async throws -> Block<Subtitles> {
        try await call {
            switch try await client.subtitles_api_v1_subtitles_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func history() async throws -> [ArrApp: Block<[HistoryItem]>] {
        try await call {
            switch try await client.history_api_v1_history_get() {
            case let .ok(ok):
                let body = try ok.body.json
                var out: [ArrApp: Block<[HistoryItem]>] = [.radarr: Block(body.radarr), .sonarr: Block(body.sonarr)]
                if let readarr = body.readarr { out[.readarr] = Block(readarr) }
                return out
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func indexerStats() async throws -> Block<IndexerStats> {
        try await call {
            switch try await client.indexer_stats_api_v1_indexers_stats_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func statsHistory(days: Int) async throws -> [StatsSample] {
        try await call {
            switch try await client.stats_history_api_v1_stats_history_get(query: .init(days: days)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func act(on requestID: Int, _ action: RequestAction) async throws {
        try await call {
            switch try await client.request_action_api_v1_requests__request_id___action__post(
                path: .init(request_id: requestID, action: action.rawValue)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws {
        try await call {
            switch try await client.subtitle_search_api_v1_subtitles_search_post(
                body: .json(.init(id: id, kind: kind == .movie ? .movie : .episode, series_id: seriesID))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func forceImport(app: ArrApp, id: Int) async throws {
        try await call {
            switch try await client.force_import_api_v1_queue__app___item_id__force_import_post(
                path: .init(app: app.rawValue, item_id: id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func blocklistRetry(app: ArrApp, id: Int) async throws {
        try await call {
            switch try await client.blocklist_retry_api_v1_queue__app___item_id__blocklist_retry_post(
                path: .init(app: app.rawValue, item_id: id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    /// Everything that is not already an APIError is a transport failure:
    /// no route, a timeout, or a body that was not the JSON the spec promised
    /// (a reverse proxy's HTML error page, say).
    func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as APIError {
            throw error
        } catch let error as ClientError {
            throw APIError.transport(error.underlyingError.localizedDescription)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }
}
