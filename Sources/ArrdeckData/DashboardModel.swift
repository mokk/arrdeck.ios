import Foundation
import Observation

/// The dashboard's state: one `Loadable` per card, each kept fresh by its own
/// poll loop at the PWA's cadence, gated on which services the backend says
/// are configured.
///
/// A card's loop never blanks what it has. A failed poll keeps the last
/// answer on screen and notes the failure in `cardErrors`; only a card that
/// has never loaded shows `failed`.
@MainActor @Observable
public final class DashboardModel {
    public enum Card: CaseIterable, Sendable, Hashable {
        case sessions, health, requests, recent, torrents, queue, calendar
        case diskSpace, vpn, subtitles, history, indexers
    }

    public private(set) var configured: Set<String> = []
    public private(set) var servicesKnown = false
    /// Where each arr's own web UI lives, for "Open in Radarr".
    public private(set) var webURLs: [String: URL] = [:]

    public private(set) var sessions: Loadable<Block<[PlaySession]>> = .loading
    public private(set) var health: Loadable<Block<[HealthWarning]>> = .loading
    public private(set) var requests: Loadable<Block<[MediaRequest]>> = .loading
    public private(set) var recent: Loadable<[RecentItem]> = .loading
    public private(set) var torrents: Loadable<[TorrentClient: Block<TorrentSummary>]> = .loading
    public private(set) var queue: Loadable<[ArrApp: Block<[QueueItem]>]> = .loading
    public private(set) var calendar: Loadable<[ArrApp: Block<[CalendarItem]>]> = .loading
    public private(set) var diskSpace: Loadable<Block<[DiskSpace]>> = .loading
    public private(set) var vpn: Loadable<Block<VpnStatus>> = .loading
    public private(set) var subtitles: Loadable<Block<Subtitles>> = .loading
    public private(set) var history: Loadable<[ArrApp: Block<[HistoryItem]>]> = .loading
    public private(set) var indexers: Loadable<Block<IndexerStats>> = .loading

    /// The most recent failure to list the services, which every card waits
    /// on. Cleared by the next call that gets through, whichever card makes
    /// it. A card's own failure is that card's problem and stays out of here.
    public private(set) var connectionError: String?
    /// Each card's most recent poll failure while it still shows older data;
    /// cleared by that card's next success.
    public private(set) var cardErrors: [Card: String] = [:]
    /// When each card last got an answer, identical or not. The widgets'
    /// snapshot is timed by this: an unchanged answer is still a fresh one.
    public private(set) var answeredAt: [Card: Date] = [:]
    /// A user action (approve, retry…) that the backend refused. Settable so
    /// the view can dismiss it.
    public var actionError: String?
    public private(set) var pending: Set<String> = []

    private let api: any DashboardAPI
    private let cadence: Cadence
    private var cards: [Card: Runner] = [:]

    private struct Runner: Sendable {
        let enabled: @MainActor @Sendable () -> Bool
        /// One fetch: stores the result, returns when to fetch next, or nil to stop.
        let step: @MainActor @Sendable () async -> TimeInterval?
    }

    public init(
        api: any DashboardAPI,
        cadence: Cadence = .standard
    ) {
        self.api = api
        self.cadence = cadence
        let c = cadence
        cards = [
            .sessions: runner(.sessions, \.sessions, enabled: { [unowned self] in has("plex") },
                              every: { Motion.sessionsMoving($0) ? c.fast : c.idle }) { try await api.playSessions() },
            .health: runner(.health, \.health, enabled: { [unowned self] in hasArr }, every: { _ in c.slow }) { try await api.health() },
            .requests: runner(.requests, \.requests, enabled: { [unowned self] in has("overseerr") }, every: { _ in c.medium }) { try await api.pendingRequests() },
            .recent: runner(.recent, \.recent, every: { _ in c.recent }) { try await api.recent() },
            .torrents: runner(.torrents, \.torrents, enabled: { [unowned self] in !torrentClients.isEmpty },
                              every: { Motion.summaryMoving($0) ? c.fast : c.idle }) { try await api.torrentSummary() },
            .queue: runner(.queue, \.queue, enabled: { [unowned self] in hasArr },
                           every: { Motion.queueMoving($0) ? c.fast : c.idle }) { try await api.queue() },
            .calendar: runner(.calendar, \.calendar, enabled: { [unowned self] in hasArr }, every: { _ in c.slow }) { try await api.calendar() },
            .diskSpace: runner(.diskSpace, \.diskSpace, enabled: { [unowned self] in hasArr }, every: { _ in c.slow }) { try await api.diskSpace() },
            .vpn: runner(.vpn, \.vpn, enabled: { [unowned self] in has("gluetun") }, every: { _ in c.medium }) { try await api.vpn() },
            .subtitles: runner(.subtitles, \.subtitles, enabled: { [unowned self] in has("bazarr") }, every: { _ in c.slow }) { try await api.subtitles() },
            .history: runner(.history, \.history, enabled: { [unowned self] in hasArr }, every: { _ in c.medium }) { try await api.history() },
            .indexers: runner(.indexers, \.indexers, enabled: { [unowned self] in has("prowlarr") }, every: { _ in c.slow }) { try await api.indexerStats() },
        ]
    }

    // MARK: Gating

    public func has(_ service: String) -> Bool { configured.contains(service) }
    public var hasArr: Bool { ArrApp.allCases.contains { has($0.rawValue) } }
    public var torrentClients: [TorrentClient] { TorrentClient.allCases.filter { has($0.rawValue) } }

    public func isPending(_ key: String) -> Bool { pending.contains(key) }

    // MARK: Lifecycle

    /// Polls until cancelled. Services come first: every gate depends on them,
    /// so an unreachable backend is retried here rather than by thirteen loops
    /// that would all fail the same way.
    public func run() async {
        while !Task.isCancelled {
            if await loadServices() { break }
            try? await Task.sleep(for: .seconds(cadence.medium))
        }
        guard !Task.isCancelled else { return }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.pollServices() }
            for runner in self.cards.values {
                group.addTask { await self.poll(runner) }
            }
        }
    }

    /// One pass over everything enabled, for pull-to-refresh.
    public func refresh() async {
        await loadServices()
        await step(cards.keys)
    }

    private func step(_ ids: some Sequence<Card>) async {
        let runners = ids.compactMap { cards[$0] }.filter { $0.enabled() }
        await withDiscardingTaskGroup { group in
            for runner in runners {
                group.addTask { _ = await runner.step() }
            }
        }
    }

    /// Whether the services answered.
    @discardableResult
    private func loadServices() async -> Bool {
        do {
            let list = try await api.services()
            configured = Set(list.filter(\.configured).map(\.service))
            webURLs = list.reduce(into: [:]) { urls, info in
                if let raw = info.web_url, let url = URL(string: raw) { urls[info.service] = url }
            }
            servicesKnown = true
            connectionError = nil
            return true
        } catch {
            connectionError = describe(error)
            return false
        }
    }

    private func pollServices() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(cadence.slow))
            guard !Task.isCancelled else { return }
            await loadServices()
        }
    }

    private func poll(_ runner: Runner) async {
        while !Task.isCancelled {
            guard runner.enabled() else {
                try? await Task.sleep(for: .seconds(cadence.slow))
                continue
            }
            guard let next = await runner.step() else { return }
            try? await Task.sleep(for: .seconds(next))
        }
    }

    private func runner<Value: Sendable & Equatable>(
        _ card: Card,
        _ keyPath: ReferenceWritableKeyPath<DashboardModel, Loadable<Value>>,
        enabled: @escaping @MainActor @Sendable () -> Bool = { true },
        every interval: @escaping @Sendable (Value) -> TimeInterval,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> Runner {
        Runner(enabled: enabled) { [weak self] in
            guard let self else { return nil }
            do {
                let value = try await fetch()
                self[keyPath: keyPath] = .loaded(value)
                cardErrors[card] = nil
                answeredAt[card] = .now
                connectionError = nil
                return interval(value)
            } catch is CancellationError {
                return nil
            } catch {
                let reason = describe(error)
                if case .loading = self[keyPath: keyPath] {
                    self[keyPath: keyPath] = .failed(reason)
                } else {
                    cardErrors[card] = reason
                }
                return cadence.medium
            }
        }
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }

    // MARK: Actions

    public func act(on request: MediaRequest, _ action: RequestAction) async {
        await perform("request-\(request.id)") { try await api.act(on: request.id, action) }
        await step([.requests, .queue])
    }

    public func searchSubtitles(_ item: SubtitleItem) async {
        let kind: SubtitleKind = item.kind == "episode" ? .episode : .movie
        await perform("subtitles-\(item.kind)-\(item.id)") {
            try await api.searchSubtitles(kind: kind, id: item.id, seriesID: item.series_id)
        }
        await step([.subtitles])
    }

    public func forceImport(_ item: QueueItem) async {
        guard let app = item.arr else { return }
        await perform("queue-\(item.app)-\(item.id)") { try await api.forceImport(app: app, id: item.id) }
        await step([.queue])
    }

    public func blocklistRetry(_ item: QueueItem) async {
        guard let app = item.arr else { return }
        await perform("queue-\(item.app)-\(item.id)") { try await api.blocklistRetry(app: app, id: item.id) }
        await step([.queue])
    }

    private func perform(_ key: String, _ work: @Sendable () async throws -> Void) async {
        pending.insert(key)
        defer { pending.remove(key) }
        do {
            try await work()
        } catch {
            actionError = describe(error)
        }
    }
}
