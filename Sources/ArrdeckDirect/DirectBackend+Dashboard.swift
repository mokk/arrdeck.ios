import ArrdeckData
import Foundation

extension DirectBackend: DashboardAPI {
    /// Which services there are, which are set up, and where each one's own
    /// web page is, for "Open in Radarr".
    public func services() async throws -> [ServiceInfo] {
        DirectServices.all.compactMap { name in
            let configured = registry.isConfigured(name)
            guard DirectServices.listed(name, configured: configured), Services.known.contains(name) else { return nil }
            let web = configured && DirectServices.webUI.contains(name) ? registry.connection(name).url : nil
            return ServiceInfo(configured: configured, service: name, web_url: web)
        }
    }

    public func playSessions() async throws -> Block<[PlaySession]> {
        throw APIError.needsServer
    }

    public func health() async throws -> Block<[HealthWarning]> {
        throw APIError.needsServer
    }

    public func pendingRequests() async throws -> Block<[MediaRequest]> {
        throw APIError.needsServer
    }

    public func recent() async throws -> [RecentItem] {
        throw APIError.needsServer
    }

    public func torrentSummary() async throws -> [TorrentClient: Block<TorrentSummary>] {
        throw APIError.needsServer
    }

    public func queue() async throws -> [ArrApp: Block<[QueueItem]>] {
        throw APIError.needsServer
    }

    public func calendar() async throws -> [ArrApp: Block<[CalendarItem]>] {
        throw APIError.needsServer
    }

    public func diskSpace() async throws -> Block<[DiskSpace]> {
        throw APIError.needsServer
    }

    public func vpn() async throws -> Block<VpnStatus> {
        throw APIError.needsServer
    }

    public func subtitles() async throws -> Block<Subtitles> {
        throw APIError.needsServer
    }

    public func history() async throws -> [ArrApp: Block<[HistoryItem]>] {
        throw APIError.needsServer
    }

    public func indexerStats() async throws -> Block<IndexerStats> {
        throw APIError.needsServer
    }

    public func statsHistory(days: Int) async throws -> [StatsSample] {
        throw APIError.needsServer
    }

    public func act(on requestID: Int, _ action: RequestAction) async throws {
        throw APIError.needsServer
    }

    public func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws {
        throw APIError.needsServer
    }

    public func forceImport(app: ArrApp, id: Int) async throws {
        throw APIError.needsServer
    }

    public func blocklistRetry(app: ArrApp, id: Int) async throws {
        throw APIError.needsServer
    }
}
