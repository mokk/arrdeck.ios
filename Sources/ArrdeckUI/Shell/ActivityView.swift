import ArrdeckData
import SwiftUI

/// Everything about downloads in one tab. History comes first — grabs,
/// imports and the blocklist, with what arrived since the last visit marked
/// NEW. Downloading is what is moving right now — the arr queue with its
/// import/retry actions, then the torrents with a live transfer — and Queue
/// is the full torrent list.
public struct ActivityView: View {
    enum Segment: CaseIterable {
        case history, downloading, queue
        var label: String {
            switch self {
            case .downloading: String(localized: "Downloading")
            case .queue: String(localized: "Queue")
            case .history: String(localized: "History")
            }
        }
    }

    @State private var segment: Segment = .history
    @State private var model: DownloadsModel
    let feed: ActivityFeedModel
    let api: any DownloadsAPI & ExtrasAPI & HistoryAPI & LibraryAPI
    let hasArr: Bool
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void

    public init(
        api: any DownloadsAPI & ExtrasAPI & HistoryAPI & LibraryAPI, feed: ActivityFeedModel, clients: [TorrentClient], hasArr: Bool,
        baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.feed = feed
        self.hasArr = hasArr
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
        _model = State(initialValue: DownloadsModel(api: api, clients: clients, hasArr: hasArr, onSessionLost: onSessionLost))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.grouped)
            switch segment {
            case .downloading:
                DownloadingList(model: model, api: api, onSessionLost: onSessionLost) { segment = .queue }
            case .queue:
                DownloadsView(model: model, api: api, onSessionLost: onSessionLost)
            case .history:
                HistoryScreen(api: api, newSince: feed.lastSeen, onShown: { feed.markSeen(at: .now) },
                              titled: false, onSessionLost: onSessionLost)
            }
        }
        .navigationTitle("Activity")
        .navigationDestination(for: MediaRef.self) { ref in
            switch ref {
            case let .movie(id):
                MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            case let .series(id):
                SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            case let .book(id):
                BookDetailView(id: id, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
            }
        }
        .task { await model.run() }
        .accessibilityIdentifier("activity")
    }
}

/// The arr queue and the torrents that are moving. Seeding-only torrents
/// stay in Queue; here is what you look at while waiting.
struct DownloadingList: View {
    let model: DownloadsModel
    let api: any DownloadsAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void
    let showAll: () -> Void
    @State private var adding = false
    @State private var selected: Torrent?

    static let movingStates: Set<String> = ["downloading", "checking", "queued", "stalled"]

    var active: [Torrent] {
        model.shown.filter { Self.movingStates.contains($0.state) || $0.dl_speed > 0 || $0.ul_speed > 0 }
            .sorted { ($0.dl_speed + $0.ul_speed) > ($1.dl_speed + $1.ul_speed) }
    }

    var totals: (down: Int, up: Int) {
        let groups = model.clients.compactMap { model.torrents.value?[$0]?.value }
        return (groups.reduce(0) { $0 + $1.totals.dl_speed }, groups.reduce(0) { $0 + $1.totals.ul_speed })
    }

    var body: some View {
        List {
            if let error = model.connectionError {
                Section { Label(error, systemImage: "wifi.slash").font(.subheadline).foregroundStyle(Color.warning) }
            }
            if model.hasArr {
                Section("Radarr / Sonarr") {
                    switch model.queue {
                    case .loading: LoadingRow()
                    case let .failed(reason): ErrorNote(reason)
                    case let .loaded(blocks):
                        let items = ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] }
                        if items.isEmpty { EmptyNote("Nothing in the queue") }
                        ForEach(items, id: \.id) { item in
                            QueueRow(
                                item: item,
                                pending: model.isPending("queue-\(item.app.rawValue)-\(item.id)"),
                                forceImport: { Task { await model.forceImport(item) } },
                                retry: { Task { await model.blocklistRetry(item) } },
                                remove: { Task { await model.removeFromQueue(item) } },
                                grab: { Task { await model.grabNow(item) } }
                            )
                        }
                    }
                }
            }
            if !model.clients.isEmpty {
                Section {
                    RefreshNote(error: model.refreshError)
                    switch model.torrents {
                    case .loading: LoadingRow()
                    case let .failed(reason): ErrorNote(reason)
                    case .loaded:
                        if active.isEmpty { EmptyNote("Nothing is transferring") }
                        ForEach(active, id: \.key) { torrent in
                            TorrentRow(torrent: torrent)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = torrent }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await model.togglePaused(torrent) }
                                    } label: {
                                        Label(torrent.isPaused ? "Resume" : "Pause", systemImage: torrent.isPaused ? "play.fill" : "pause.fill")
                                    }
                                    .tint(Color.accent)
                                }
                        }
                    }
                    Button {
                        showAll()
                    } label: {
                        Text("\(active.count) active of \(model.matchTotal) torrents · Show all").font(.caption)
                    }
                } header: {
                    HStack {
                        Text("Torrents")
                        Spacer()
                        Text("↓ \(Format.speed(totals.down)) · ↑ \(Format.speed(totals.up))").textCase(nil)
                    }
                }
            }
        }
        .dashboardListStyle()
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.clients.isEmpty {
                    Button {
                        Task { await model.toggleThrottle() }
                    } label: {
                        Label(model.isThrottled ? "Throttled" : "Throttle", systemImage: "tortoise")
                            .symbolVariant(model.isThrottled ? .fill : .none)
                    }
                    .tint(model.isThrottled ? Color.warning : nil)
                    .disabled(model.isPending("throttle"))
                    Button { adding = true } label: { Label("Add torrent", systemImage: "plus") }
                        .accessibilityIdentifier("add-torrent")
                }
            }
        }
        .sheet(item: $selected) { torrent in
            TorrentDetailSheet(torrent: torrent, model: model, api: api, onSessionLost: onSessionLost) { selected = nil }
        }
        .sheet(isPresented: $adding) {
            AddTorrentSheet(clients: model.clients, api: api, onSessionLost: onSessionLost) {
                adding = false
                Task { await model.refresh() }
            }
        }
        .accessibilityIdentifier("downloading")
    }
}
