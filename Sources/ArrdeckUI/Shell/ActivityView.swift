import ArrdeckData
import SwiftUI

/// Everything about downloads in one tab. History comes first — grabs,
/// imports and the blocklist. What arrived since the last visit is marked NEW
/// there and on finished torrents, against one cutoff taken here: History
/// moves the mark once shown, and the torrent lists must still see the old one. Downloading is what is moving right now — the arr queue with its
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
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var chromeTab
    @State private var model: DownloadsModel
    @State private var newSince: Date
    let feed: ActivityFeedModel
    let api: any DownloadsAPI & HistoryAPI & TitleScreensAPI
    let hasArr: Bool
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void

    public init(
        api: any DownloadsAPI & HistoryAPI & TitleScreensAPI, feed: ActivityFeedModel, clients: [TorrentClient], hasArr: Bool,
        arrs: [ArrApp] = [], baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.feed = feed
        self.hasArr = hasArr
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
        _model = State(initialValue: DownloadsModel(
            api: api, clients: clients, hasArr: hasArr, arrs: arrs, onSessionLost: onSessionLost
        ))
        _newSince = State(initialValue: feed.lastSeen)
    }

    var picker: some View {
        Picker("Section", selection: $segment) {
            ForEach(Segment.allCases, id: \.self) { segment in
                // stuck downloads are counted on the segment that lists them
                if segment == .downloading, model.attentionCount > 0 {
                    Text(verbatim: "\(segment.label) (\(model.attentionCount))").tag(segment)
                } else {
                    Text(segment.label).tag(segment)
                }
            }
        }
        .pickerStyle(.segmented)
    }

    /// With no navigation bar: the segments pinned over the list, folding
    /// away with the tab bar as the list scrolls down. The list keeps their
    /// room at its top, so nothing jumps.
    var header: some View {
        let out = chrome?.isExpanded ?? true
        return picker
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.grouped)
            .opacity(out ? 1 : 0)
            .offset(y: out ? 0 : -24)
            .allowsHitTesting(out)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if chromeTab == nil {
                picker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.grouped)
            }
            switch segment {
            case .downloading:
                DownloadingList(model: model, api: api, newSince: newSince, onSessionLost: onSessionLost) { segment = .queue }
            case .queue:
                DownloadsView(model: model, api: api, newSince: newSince, onSessionLost: onSessionLost)
            case .history:
                HistoryScreen(api: api, apps: model.arrs, newSince: newSince, onShown: { feed.markSeen(at: .now) },
                              titled: false, onSessionLost: onSessionLost)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if chromeTab != nil { header }
        }
        // each segment's list reports its own scrolling
        .chromePage(reportsScroll: false)
        .onChange(of: segment) { _, _ in chrome?.reset() }
        .navigationTitle("Activity")
        .pageTitle()
        .navigationDestination(for: MediaRef.self) { ref in
            TitleDetail(ref: ref, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
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
    let newSince: Date?
    let onSessionLost: @MainActor () -> Void
    let showAll: () -> Void
    @State private var adding = false
    @State private var selected: Torrent?
    @State private var importing: ImportJob?

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
            if model.attentionCount > 0 {
                NeedsAttentionSection(model: model) { importing = $0 }
            }
            if model.hasArr {
                Section("Radarr / Sonarr") {
                    switch model.queue {
                    case .loading: LoadingRow()
                    case let .failed(reason): ErrorNote(reason)
                    case let .loaded(blocks):
                        let items = ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] }
                        if items.isEmpty { EmptyNote("Nothing in the queue") }
                        ForEach(items, id: \.rowID) { item in
                            QueueRow(
                                item: item,
                                pending: model.isPending("queue-\(item.app)-\(item.id)"),
                                forceImport: { Task { await model.forceImport(item) } },
                                retry: { Task { await model.blocklistRetry(item) } },
                                remove: { Task { await model.removeFromQueue(item) } },
                                grab: { Task { await model.grabNow(item) } },
                                fix: { importing = ImportJob(item) }
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
                            TorrentRow(torrent: torrent, newSince: newSince)
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
        .reportsChromeScroll()
        .refreshable { await model.refresh() }
        .chromeActions {
            if !model.clients.isEmpty {
                Button {
                    Task { await model.toggleThrottle() }
                } label: {
                    Label(model.isThrottled ? "Throttled" : "Throttle", systemImage: "tortoise")
                        .symbolVariant(model.isThrottled ? .fill : .none)
                }
                .tint(model.isThrottled ? Color.warning : nil)
                .disabled(model.isPending("throttle"))
                .accessibilityIdentifier("throttle")
                Button { adding = true } label: { Label("Add torrent", systemImage: "plus") }
                    .accessibilityIdentifier("add-torrent")
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
        .sheet(item: $importing) { job in
            ImportSheet(job: job, api: api, onSessionLost: onSessionLost,
                        onFinished: { Task { await model.refreshQueue() } }) { importing = nil }
        }
        .accessibilityIdentifier("downloading")
    }
}

extension ImportJob {
    /// A stuck queue item; its title is the release, as the arr names it.
    init?(_ item: QueueItem) {
        guard let app = item.arr else { return nil }
        self.init(source: .queue(app: app, itemID: item.id), title: item.title)
    }
}

/// Downloads the arrs will not import on their own, each with the arr's
/// reason, first on the page because nothing else moves until they are fixed.
struct NeedsAttentionSection: View {
    let model: DownloadsModel
    let fix: (ImportJob) -> Void

    var body: some View {
        Section {
            ForEach(model.attentionItems, id: \.attentionKey) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            StateBadge(state: item.app)
                            if let state = item.tracked_state { StateBadge(state: state) }
                        }
                        ForEach(item.attentionReasons, id: \.self) { reason in
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if let job = ImportJob(item) {
                        Button("Fix") { fix(job) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .accessibilityIdentifier("attention-fix")
                    }
                }
            }
            if let unavailable = model.attention?.unavailable, !unavailable.isEmpty {
                // an arr that didn't answer may have stuck items of its own
                Text("Not checked: \(unavailable.map(Services.label).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warning)
                Text("Needs attention")
                Text(verbatim: "\(model.attentionCount)")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.warning, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .accessibilityIdentifier("needs-attention")
    }
}

extension QueueItem {
    /// Queue ids are per arr; Radarr's 12 and Sonarr's 12 are different rows.
    var attentionKey: String { "\(app)-\(id)" }
}
