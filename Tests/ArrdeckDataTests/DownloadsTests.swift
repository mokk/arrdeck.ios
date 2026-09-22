import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

private func torrent(
    _ id: String, name: String = "n", state: String = "seeding", client: Components.Schemas.TorrentOut.clientPayload = .qbittorrent,
    addedOn: Int? = nil, ratio: Double? = nil, tracker: String? = nil, dl: Int = 0
) -> Torrent {
    .init(added_on: addedOn, client: client, dl_speed: dl, id: id, name: name, progress: 1, ratio: ratio,
          size: 100, state: state, tracker: tracker, ul_speed: 0)
}

@Suite struct TorrentSortingTests {
    @Test func missingValuesSortLastInBothDirections() {
        let rows = [torrent("a", ratio: 1.5), torrent("b", ratio: nil), torrent("c", ratio: 0.2)]
        #expect(TorrentSorting.sort(rows, by: .ratio, descending: true).map(\.id) == ["a", "c", "b"])
        #expect(TorrentSorting.sort(rows, by: .ratio, descending: false).map(\.id) == ["c", "a", "b"])
    }

    @Test func textIsCaseInsensitive() {
        let rows = [torrent("1", name: "beta"), torrent("2", name: "Alpha"), torrent("3", name: "gamma")]
        #expect(TorrentSorting.sort(rows, by: .name, descending: false).map(\.name) == ["Alpha", "beta", "gamma"])
        #expect(TorrentSorting.sort(rows, by: .name, descending: true).map(\.name) == ["gamma", "beta", "Alpha"])
    }

    @Test func pausedMeansPausedOrCompleted() {
        #expect(torrent("a", state: "paused").isPaused)
        #expect(torrent("a", state: "completed").isPaused)
        #expect(!torrent("a", state: "seeding").isPaused)
    }

    @Test func keyIncludesTheClient() {
        #expect(torrent("12", client: .transmission).key == "transmission-12")
    }

    @Test func etaAndEpochDay() {
        #expect(Format.eta(nil) == "—")
        #expect(Format.eta(45) == "45s")
        #expect(Format.eta(150) == "3m")     // 2.5 rounds up, as Math.round does in the PWA
        #expect(Format.eta(3600 * 3 + 20 * 60) == "3h 20m")
        #expect(Format.eta(200_000) == "2d")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(Format.epochDay(1_789_752_669, calendar: utc, locale: Locale(identifier: "en_US")) == "Sep 18")
        #expect(Format.epochDay(nil) == "—")
    }
}

/// Answers the torrent list from a canned table and records each query.
actor FakeDownloadsAPI: DownloadsAPI {
    var groups: [TorrentClient: Block<TorrentGroup>]
    var queueBlocks: [ArrApp: Block<[QueueItem]>] = [.radarr: .healthy([]), .sonarr: .healthy([])]
    var limits: [TorrentClient: Bool] = [.qbittorrent: false, .transmission: false]
    var failure: APIError?
    private(set) var queries: [TorrentQuery] = []
    private(set) var calls: [String] = []

    init(groups: [TorrentClient: Block<TorrentGroup>]) { self.groups = groups }

    func set(failure: APIError?) { self.failure = failure }
    func set(groups: [TorrentClient: Block<TorrentGroup>]) { self.groups = groups }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }

    private func log(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func torrents(_ query: TorrentQuery) async throws -> [TorrentClient: Block<TorrentGroup>] {
        queries.append(query)
        try log("torrents")
        return groups
    }
    func speedLimit() async throws -> [TorrentClient: Bool] { try log("speedLimit"); return limits }
    func setSpeedLimit(_ client: TorrentClient, enabled: Bool) async throws {
        try log("throttle-\(client.rawValue)-\(enabled)")
        limits[client] = enabled
    }
    func pause(_ client: TorrentClient, ids: [String]) async throws { try log("pause-\(ids.joined())") }
    func resume(_ client: TorrentClient, ids: [String]) async throws { try log("resume-\(ids.joined())") }
    func delete(_ client: TorrentClient, ids: [String], deleteData: Bool) async throws {
        try log("delete-\(ids.joined())-\(deleteData)")
    }
    func recheck(_ client: TorrentClient, ids: [String]) async throws { try log("recheck") }
    func details(_ client: TorrentClient, id: String) async throws -> TorrentDetails {
        try log("details"); return .init(files: [])
    }
    func queue() async throws -> [ArrApp: Block<[QueueItem]>] { try log("queue"); return queueBlocks }
    func forceImport(app: ArrApp, id: Int) async throws { try log("force") }
    func blocklistRetry(app: ArrApp, id: Int) async throws { try log("retry") }
    func removeFromQueue(app: ArrApp, id: Int) async throws { try log("remove-\(app.rawValue)-\(id)") }
}

@MainActor
@Suite struct DownloadsModelTests {
    func group(_ torrents: [Torrent], total: Int? = nil, states: [String] = ["seeding"]) -> TorrentGroup {
        .init(states: states, torrents: torrents, total: total ?? torrents.count, totals: .init(dl_speed: 0, ul_speed: 0))
    }

    func model(_ api: FakeDownloadsAPI, clients: [TorrentClient] = [.qbittorrent, .transmission]) -> DownloadsModel {
        DownloadsModel(api: api, clients: clients, hasArr: true, cadence: .scaled(by: 0.01), onSessionLost: {})
    }

    @Test func mergesBothClientsAndResortsGlobally() async {
        let api = FakeDownloadsAPI(groups: [
            .qbittorrent: .healthy(group([torrent("a", addedOn: 10), torrent("c", addedOn: 30)])),
            .transmission: .healthy(group([torrent("b", client: .transmission, addedOn: 20)], states: ["paused"])),
        ])
        let model = model(api)
        await model.refresh()
        #expect(model.shown.map(\.id) == ["c", "b", "a"])
        #expect(model.states == ["paused", "seeding"])
        #expect(model.loadedCount == 3)
        #expect(!model.canLoadMore)

        model.enabledClients = [.qbittorrent]
        #expect(model.shown.map(\.id) == ["c", "a"], "the client toggle is local")
        #expect(await api.count("torrents") == 1)
    }

    @Test func queryEditsReachTheServer() async throws {
        let api = FakeDownloadsAPI(groups: [.qbittorrent: .healthy(group([])), .transmission: .healthy(group([]))])
        let model = model(api)
        await model.refresh()

        model.sort = .size
        model.descending = false
        model.stateFilter = "downloading"
        try await Task.sleep(for: .milliseconds(100))
        let last = try #require(await api.queries.last)
        #expect(last.sort == .size)
        #expect(!last.descending)
        #expect(last.state == "downloading")
        #expect(last.limit == 200)

        // typing is debounced: several edits, one request
        let before = await api.queries.count
        model.searchText = "s"
        model.searchText = "sl"
        model.searchText = "slow"
        try await Task.sleep(for: .milliseconds(500))
        #expect(await api.queries.count == before + 1)
        #expect(await api.queries.last?.text == "slow")

        model.loadMore()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await api.queries.last?.limit == 400)
    }

    @Test func loadMoreAppearsWhenTheServerHeldRowsBack() async {
        let rows = (0..<200).map { torrent("t\($0)") }
        let api = FakeDownloadsAPI(groups: [
            .qbittorrent: .healthy(group(rows, total: 485)), .transmission: .healthy(group([], total: 0)),
        ])
        let model = model(api)
        await model.refresh()
        #expect(model.matchTotal == 485)
        #expect(model.canLoadMore)
    }

    @Test func throttleIsSomeNotEveryAndTogglesBoth() async {
        let api = FakeDownloadsAPI(groups: [.qbittorrent: .healthy(group([])), .transmission: .healthy(group([]))])
        let model = model(api)
        await model.refresh()
        #expect(!model.isThrottled)
        await model.toggleThrottle()
        #expect(await api.count("throttle-qbittorrent-true") == 1)
        #expect(await api.count("throttle-transmission-true") == 1)
        #expect(model.isThrottled)
        await model.toggleThrottle()
        #expect(!model.isThrottled)
    }

    @Test func actionsRefetchAndFailuresKeepTheList() async {
        let t = torrent("abc", state: "paused")
        let api = FakeDownloadsAPI(groups: [.qbittorrent: .healthy(group([t])), .transmission: .healthy(group([]))])
        let model = model(api)
        await model.refresh()
        let before = await api.count("torrents")

        await model.togglePaused(t)
        #expect(await api.count("resume-abc") == 1)
        #expect(await api.count("torrents") == before + 1)
        await model.delete(t, deleteData: true)
        #expect(await api.count("delete-abc-true") == 1)

        await api.set(failure: .transport("timed out"))
        await model.refresh()
        #expect(model.shown.count == 1, "stale rows stay on screen")
        #expect(model.refreshError == "timed out")
        #expect(model.connectionError == "timed out")
    }

    @Test func unauthorizedStopsAndReports() async {
        let api = FakeDownloadsAPI(groups: [:])
        await api.set(failure: .unauthorized)
        var lost = 0
        let model = DownloadsModel(api: api, clients: [.qbittorrent], hasArr: false, onSessionLost: { lost += 1 })
        await model.refresh()
        #expect(lost >= 1)
    }
}
