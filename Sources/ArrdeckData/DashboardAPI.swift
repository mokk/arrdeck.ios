import ArrdeckAPI
import Foundation

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
    /// arrdeck answered, and said in words why not: "the torrent has not
    /// finished downloading". Shown as is; a status code would hide it.
    case refused(String)

    public var description: String {
        switch self {
        case .unauthorized: "signed out"
        case let .unexpectedStatus(code): "HTTP \(code)"
        case let .transport(reason): reason
        case let .refused(reason): reason
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

    func act(on requestID: Int, _ action: RequestAction) async throws
    func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws
    func forceImport(app: ArrApp, id: Int) async throws
    func blocklistRetry(app: ArrApp, id: Int) async throws
}
