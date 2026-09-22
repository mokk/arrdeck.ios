import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

/// Canned answers per call, plus a log of what was asked.
actor FakeAPI: DashboardAPI {
    var services: [ServiceInfo]
    var servicesError: APIError?
    var queueBlocks: [ArrApp: Block<[QueueItem]>] = [.radarr: .healthy([]), .sonarr: .healthy([])]
    var queueError: APIError?
    var vpnBlock: Block<VpnStatus> = .healthy(.init(public_ip: "1.2.3.4", status: "running"))
    var actionError: APIError?
    /// When set, every call fails with it — arrdeck itself is gone.
    var outage: APIError?
    private(set) var calls: [String] = []

    init(configured: [String]) {
        services = configured.map { ServiceInfo(configured: true, service: $0) }
    }

    func set(queueError: APIError?) { self.queueError = queueError }
    func set(servicesError: APIError?) { self.servicesError = servicesError }
    func set(actionError: APIError?) { self.actionError = actionError }
    func set(queue: [ArrApp: Block<[QueueItem]>]) { queueBlocks = queue }
    func set(outage: APIError?) { self.outage = outage }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    private func log(_ name: String = #function) throws {
        calls.append(name)
        if let outage { throw outage }
    }

    func services() async throws -> [ServiceInfo] {
        try log("services")
        if let servicesError { throw servicesError }
        return services
    }
    func playSessions() async throws -> Block<[PlaySession]> { try log("sessions"); return .healthy([]) }
    func health() async throws -> Block<[HealthWarning]> { try log("health"); return .healthy([]) }
    func pendingRequests() async throws -> Block<[MediaRequest]> { try log("requests"); return .healthy([]) }
    func recent() async throws -> [RecentItem] { try log("recent"); return [] }
    func torrentSummary() async throws -> [TorrentClient: Block<TorrentSummary>] { try log("torrents"); return [:] }
    func queue() async throws -> [ArrApp: Block<[QueueItem]>] {
        try log("queue")
        if let queueError { throw queueError }
        return queueBlocks
    }
    func calendar() async throws -> [ArrApp: Block<[CalendarItem]>] { try log("calendar"); return [:] }
    func diskSpace() async throws -> Block<[DiskSpace]> { try log("diskSpace"); return .healthy([]) }
    func vpn() async throws -> Block<VpnStatus> { try log("vpn"); return vpnBlock }
    func subtitles() async throws -> Block<Subtitles> { try log("subtitles"); return .healthy(.init()) }
    func history() async throws -> [ArrApp: Block<[HistoryItem]>] { try log("history"); return [:] }
    func indexerStats() async throws -> Block<IndexerStats> {
        try log("indexers")
        return .healthy(.init(enabled: 1, health: [], stats: [], total: 1))
    }
    func statsHistory(days: Int) async throws -> [StatsSample] { try log("trends"); return [] }

    func act(on requestID: Int, _ action: RequestAction) async throws {
        try log("act-\(requestID)-\(action.rawValue)")
        if let actionError { throw actionError }
    }
    func searchSubtitles(kind: SubtitleKind, id: Int, seriesID: Int?) async throws { try log("subs-\(id)") }
    func forceImport(app: ArrApp, id: Int) async throws { try log("force-\(app.rawValue)-\(id)") }
    func blocklistRetry(app: ArrApp, id: Int) async throws {
        try log("retry-\(app.rawValue)-\(id)")
        if let actionError { throw actionError }
    }
}

@MainActor
@Suite struct DashboardModelTests {
    @Test func refreshLoadsOnlyTheConfiguredCards() async {
        let api = FakeAPI(configured: ["radarr", "gluetun"])
        let model = DashboardModel(api: api, onSessionLost: {})
        await model.refresh()

        #expect(model.servicesKnown)
        #expect(model.hasArr)
        #expect(model.queue.value?[.radarr] == .healthy([]))
        #expect(model.vpn.value?.value?.status == "running")
        // gated off: no plex, no bazarr, no torrent client, no prowlarr
        #expect(model.sessions == .loading)
        #expect(model.subtitles == .loading)
        #expect(model.torrents == .loading)
        #expect(model.indexers == .loading)
        // ungated: always fetched
        #expect(model.recent == .loaded([]))
        #expect(model.trends == .loaded([]))
        #expect(await api.count("sessions") == 0)
        #expect(await api.count("queue") == 1)
    }

    @Test func failedPollKeepsTheLastAnswerAndFlagsTheCard() async {
        let api = FakeAPI(configured: ["sonarr"])
        let model = DashboardModel(api: api, onSessionLost: {})
        await model.refresh()
        #expect(model.queue.value != nil)
        #expect(model.cardErrors.isEmpty)

        await api.set(queueError: .unexpectedStatus(500))
        await model.refresh()
        #expect(model.queue.value?[.sonarr] == .healthy([]), "a failure must not blank a card")
        #expect(model.cardErrors[.queue] == "HTTP 500")
        #expect(model.connectionError == nil, "one endpoint's 500 is not a connection problem")

        await api.set(queueError: nil)
        await model.refresh()
        #expect(model.cardErrors.isEmpty)
    }

    @Test func anOutageRaisesTheConnectionBannerUntilAnythingGetsThrough() async {
        let api = FakeAPI(configured: ["sonarr", "gluetun"])
        let model = DashboardModel(api: api, onSessionLost: {})
        await model.refresh()
        #expect(model.connectionError == nil)

        await api.set(outage: .transport("Could not connect to the server."))
        await model.refresh()
        #expect(model.connectionError == "Could not connect to the server.")
        #expect(model.vpn.value?.value?.status == "running", "stale data stays on screen through an outage")

        await api.set(outage: nil)
        await model.refresh()
        #expect(model.connectionError == nil)
    }

    @Test func aCardThatNeverLoadedShowsTheFailure() async {
        let api = FakeAPI(configured: ["sonarr"])
        await api.set(queueError: .unexpectedStatus(500))
        let model = DashboardModel(api: api, onSessionLost: {})
        await model.refresh()
        #expect(model.queue == .failed("HTTP 500"))
    }

    @Test func unauthorizedEndsTheSession() async {
        let api = FakeAPI(configured: ["sonarr"])
        await api.set(servicesError: .unauthorized)
        var lost = 0
        let model = DashboardModel(api: api, onSessionLost: { lost += 1 })
        await model.refresh()
        #expect(lost == 1)
        #expect(await api.count("queue") == 0, "nothing else is asked once the session is gone")
    }

    @Test func runPollsAtTheCadenceUntilCancelled() async throws {
        let api = FakeAPI(configured: ["radarr"])
        let going = QueueItem(app: .radarr, id: 1, size: 10, size_left: 5, status: "downloading", title: "x")
        await api.set(queue: [.radarr: .healthy([going]), .sonarr: .healthy([])])
        let model = DashboardModel(api: api, cadence: .scaled(by: 0.01), onSessionLost: {})

        let task = Task { await model.run() }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        await task.value

        // fast cadence = 50ms while a queue item is moving: several polls fit
        let polls = await api.count("queue")
        #expect(polls >= 3, "got \(polls) queue polls")
        // history sits at medium (300ms scaled): fewer, but at least the first
        #expect(await api.count("history") >= 1)
        #expect(await api.count("services") >= 1)
    }

    @Test func actionsRefetchTheirCardsAndReportRefusals() async {
        let api = FakeAPI(configured: ["overseerr", "sonarr"])
        let model = DashboardModel(api: api, onSessionLost: {})
        await model.refresh()
        let before = await api.count("queue")

        await model.act(on: .init(id: 12, status: 1, _type: "movie"), .approve)
        #expect(await api.count("act-12-approve") == 1)
        #expect(await api.count("queue") == before + 1, "approving refetches the queue too")
        #expect(model.actionError == nil)

        await api.set(actionError: .unexpectedStatus(409))
        let item = QueueItem(app: .sonarr, id: 7, size: 1, size_left: 0, status: "completed", title: "t")
        await model.blocklistRetry(item)
        #expect(model.actionError == "HTTP 409")
        #expect(!model.isPending("queue-sonarr-7"))
    }
}
