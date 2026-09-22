import Foundation
import Observation

/// The Downloads screen: the merged torrent list under the user's query, the
/// arr queue above it, and the throttle. The query lives here so every edit
/// — a typed letter, a sort, a filter chip — refetches from the server, with
/// a generation counter dropping answers that arrive out of order.
@MainActor @Observable
public final class DownloadsModel {
    public static let page = 200

    public var searchText = "" {
        didSet { if searchText != oldValue { debounceSearch() } }
    }
    /// nil is every state.
    public var stateFilter: String? {
        didSet { if stateFilter != oldValue { queryChanged() } }
    }
    public var sort: TorrentSort = .addedOn {
        didSet { if sort != oldValue { queryChanged() } }
    }
    public var descending = true {
        didSet { if descending != oldValue { queryChanged() } }
    }
    /// Which clients to show. Local: the server already sent both lists.
    public var enabledClients: Set<TorrentClient>

    public private(set) var limit = DownloadsModel.page
    public private(set) var torrents: Loadable<[TorrentClient: Block<TorrentGroup>]> = .loading
    public private(set) var queue: Loadable<[ArrApp: Block<[QueueItem]>]> = .loading
    public private(set) var throttled: [TorrentClient: Bool] = [:]
    public private(set) var connectionError: String?
    public private(set) var refreshError: String?
    public var actionError: String?
    public private(set) var pending: Set<String> = []

    public let clients: [TorrentClient]
    public let hasArr: Bool

    private let api: any DownloadsAPI
    private let cadence: Cadence
    private let onSessionLost: @MainActor () -> Void
    private var generation = 0
    private var debounce: Task<Void, Never>?
    private var stopped = false

    public init(
        api: any DownloadsAPI,
        clients: [TorrentClient],
        hasArr: Bool,
        cadence: Cadence = .standard,
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.clients = clients
        self.hasArr = hasArr
        self.cadence = cadence
        self.onSessionLost = onSessionLost
        enabledClients = Set(clients)
    }

    // MARK: Derived

    public var query: TorrentQuery {
        TorrentQuery(text: searchText, state: stateFilter, sort: sort, descending: descending, limit: limit)
    }

    var all: [Torrent] {
        clients.flatMap { torrents.value?[$0]?.value?.torrents ?? [] }
    }

    /// The merged lists, re-sorted so the visible order is globally correct,
    /// narrowed to the enabled clients.
    public var shown: [Torrent] {
        TorrentSorting.sort(all.filter { enabledClients.contains($0.torrentClient) }, by: sort, descending: descending)
    }

    /// Every state either client knows, for the filter chips.
    public var states: [String] {
        Set(clients.flatMap { torrents.value?[$0]?.value?.states ?? [] }).sorted()
    }

    public var loadedCount: Int { all.count }

    /// Rows matching the query across both clients, including those the
    /// server held back beyond `limit`.
    public var matchTotal: Int {
        clients.reduce(0) { $0 + (torrents.value?[$1]?.value?.total ?? 0) }
    }

    public var canLoadMore: Bool { matchTotal > shown.count && shown.count >= limit }

    /// "some", not "every": if either client is throttled the label has to
    /// say so, otherwise a half-applied state reads as off.
    public var isThrottled: Bool { clients.contains { throttled[$0] == true } }

    public func offlineReason(_ client: TorrentClient) -> String? {
        torrents.value?[client]?.offlineReason
    }

    public func isPending(_ key: String) -> Bool { pending.contains(key) }

    // MARK: Lifecycle

    public func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.pollTorrents() }
            if hasArr { group.addTask { await self.pollQueue() } }
            if !clients.isEmpty { group.addTask { await self.pollThrottle() } }
        }
    }

    public func refresh() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.fetchTorrents() }
            if self.hasArr { group.addTask { await self.fetchQueue() } }
            if !self.clients.isEmpty { group.addTask { await self.fetchThrottle() } }
        }
    }

    public func loadMore() {
        limit += DownloadsModel.page
        queryChanged()
    }

    private func debounceSearch() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await fetchTorrents()
        }
    }

    private func queryChanged() {
        Task { await fetchTorrents() }
    }

    private func pollTorrents() async {
        while !Task.isCancelled, !stopped {
            await fetchTorrents()
            let moving = torrents.value.map(Motion.torrentsMoving) ?? false
            try? await Task.sleep(for: .seconds(moving ? cadence.fast : cadence.idle))
        }
    }

    private func pollQueue() async {
        while !Task.isCancelled, !stopped {
            await fetchQueue()
            let moving = queue.value.map(Motion.queueMoving) ?? false
            try? await Task.sleep(for: .seconds(moving ? cadence.fast : cadence.idle))
        }
    }

    private func pollThrottle() async {
        while !Task.isCancelled, !stopped {
            await fetchThrottle()
            try? await Task.sleep(for: .seconds(cadence.medium))
        }
    }

    func fetchTorrents() async {
        generation += 1
        let mine = generation
        let query = query
        do {
            let result = try await api.torrents(query)
            guard mine == generation else { return }   // a newer query answered first
            torrents = .loaded(result)
            refreshError = nil
            connectionError = nil
        } catch {
            guard mine == generation else { return }
            handle(error, keeping: torrents.value != nil) { torrents = .failed($0) }
        }
    }

    private func fetchQueue() async {
        do {
            queue = .loaded(try await api.queue())
            connectionError = nil
        } catch {
            handle(error, keeping: queue.value != nil) { queue = .failed($0) }
        }
    }

    private func fetchThrottle() async {
        do {
            throttled = try await api.speedLimit()
        } catch {
            handle(error, keeping: true) { _ in }
        }
    }

    private func handle(_ error: any Error, keeping: Bool, otherwise fail: (String) -> Void) {
        if case .some(.unauthorized) = error as? APIError {
            stopped = true
            onSessionLost()
            return
        }
        if error is CancellationError { return }
        let reason = describe(error)
        if keeping { refreshError = reason } else { fail(reason) }
        if case .transport = error as? APIError { connectionError = reason }
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }

    // MARK: Actions

    public func togglePaused(_ torrent: Torrent) async {
        await perform(torrent.key) {
            if torrent.isPaused {
                try await api.resume(torrent.torrentClient, ids: [torrent.id])
            } else {
                try await api.pause(torrent.torrentClient, ids: [torrent.id])
            }
        }
        await fetchTorrents()
    }

    public func delete(_ torrent: Torrent, deleteData: Bool) async {
        await perform(torrent.key) {
            try await api.delete(torrent.torrentClient, ids: [torrent.id], deleteData: deleteData)
        }
        await fetchTorrents()
    }

    public func recheck(_ torrent: Torrent) async {
        await perform(torrent.key) { try await api.recheck(torrent.torrentClient, ids: [torrent.id]) }
    }

    public func details(for torrent: Torrent) async throws -> TorrentDetails {
        try await api.details(torrent.torrentClient, id: torrent.id)
    }

    /// One call per client: they do not share a throttle. Applies the
    /// opposite of the aggregate, so a half-applied state resolves to off.
    public func toggleThrottle() async {
        let enable = !isThrottled
        await perform("throttle") {
            for client in clients {
                try await api.setSpeedLimit(client, enabled: enable)
            }
        }
        await fetchThrottle()
    }

    public func forceImport(_ item: QueueItem) async {
        guard let app = ArrApp(rawValue: item.app.rawValue) else { return }
        await perform("queue-\(item.app.rawValue)-\(item.id)") { try await api.forceImport(app: app, id: item.id) }
        await fetchQueue()
    }

    public func blocklistRetry(_ item: QueueItem) async {
        guard let app = ArrApp(rawValue: item.app.rawValue) else { return }
        await perform("queue-\(item.app.rawValue)-\(item.id)") { try await api.blocklistRetry(app: app, id: item.id) }
        await fetchQueue()
    }

    public func removeFromQueue(_ item: QueueItem) async {
        guard let app = ArrApp(rawValue: item.app.rawValue) else { return }
        await perform("queue-\(item.app.rawValue)-\(item.id)") { try await api.removeFromQueue(app: app, id: item.id) }
        await fetchQueue()
    }

    private func perform(_ key: String, _ work: @Sendable () async throws -> Void) async {
        pending.insert(key)
        defer { pending.remove(key) }
        do {
            try await work()
        } catch APIError.unauthorized {
            stopped = true
            onSessionLost()
        } catch {
            actionError = describe(error)
        }
    }
}
