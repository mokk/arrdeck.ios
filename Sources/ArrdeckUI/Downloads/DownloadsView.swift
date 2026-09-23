import ArrdeckData
import SwiftUI

/// The PWA's Downloads page: the merged torrent list under a server-side
/// query, swipe to pause or delete, tap for detail, the arr queue below.
public struct DownloadsView: View {
    @State private var model: DownloadsModel
    @State private var selected: Torrent?
    @State private var deleting: Torrent?
    @State private var adding = false
    @State private var confirmingBulkDelete = false
    let api: any DownloadsAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void
    /// Inside the Activity tab the model is shared and already polling.
    private var embedded = false

    public init(
        api: any DownloadsAPI & ExtrasAPI,
        clients: [TorrentClient],
        hasArr: Bool,
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.onSessionLost = onSessionLost
        _model = State(initialValue: DownloadsModel(
            api: api, clients: clients, hasArr: hasArr, onSessionLost: onSessionLost
        ))
    }

    /// Embedded in the Activity tab, sharing its model with the Downloading
    /// segment.
    init(model: DownloadsModel, api: any DownloadsAPI & ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
        self.embedded = true
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            if let error = model.connectionError {
                Section {
                    Label(error, systemImage: "wifi.slash").font(.subheadline).foregroundStyle(.orange)
                }
            }
            ForEach(model.clients, id: \.self) { client in
                if let reason = model.offlineReason(client) {
                    Section { ErrorNote("\(Services.label(client.rawValue)) offline — \(reason)") }
                }
            }

            Section {
                RefreshNote(error: model.refreshError)
                switch model.torrents {
                case .loading:
                    LoadingRow()
                case let .failed(reason):
                    ErrorNote(reason)
                case .loaded:
                    ForEach(model.shown, id: \.key) { torrent in
                        HStack(spacing: 10) {
                            if model.selecting {
                                Image(systemName: model.selected.contains(torrent.key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selected.contains(torrent.key) ? Color.accentColor : Color.secondary)
                            }
                            TorrentRow(torrent: torrent)
                        }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if model.selecting { model.toggleSelection(torrent) } else { selected = torrent }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleting = torrent
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await model.togglePaused(torrent) }
                                } label: {
                                    Label(torrent.isPaused ? "Resume" : "Pause",
                                          systemImage: torrent.isPaused ? "play.fill" : "pause.fill")
                                }
                                .tint(.blue)
                            }
                            .accessibilityIdentifier("torrent-row")
                    }
                    if model.shown.isEmpty {
                        EmptyNote("No torrents match the filters")
                    }
                    if model.canLoadMore {
                        HStack {
                            Text("Showing \(model.shown.count) of \(model.matchTotal)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load more") { model.loadMore() }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("\(model.shown.count) of \(model.loadedCount) torrents")
                    .accessibilityIdentifier("torrent-count")
            }

            if model.hasArr, let items = model.queue.value.map({ blocks in ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] } }),
               !items.isEmpty {
                Section("Radarr / Sonarr queue") {
                    ForEach(items, id: \.id) { item in
                        QueueRow(
                            item: item,
                            pending: model.isPending("queue-\(item.app.rawValue)-\(item.id)"),
                            forceImport: { Task { await model.forceImport(item) } },
                            retry: { Task { await model.blocklistRetry(item) } },
                            remove: { Task { await model.removeFromQueue(item) } }
                        )
                    }
                }
            }
        }
        .dashboardListStyle()
        .searchable(text: $model.searchText, prompt: "Filter by name…")
        .refreshable { await model.refresh() }
        .task { if !embedded { await model.run() } }
        .navigationTitle(embedded ? "Activity" : "Downloads")
        .safeAreaInset(edge: .bottom) {
            // Above the tab bar: a bottomBar toolbar item lands behind it.
            if model.selecting { BulkBarChrome { bulkBar } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(model.selecting ? "Done" : "Select") { model.selecting.toggle() }
                    .accessibilityIdentifier("select")
                if !model.clients.isEmpty {
                    Button { adding = true } label: { Label("Add torrent", systemImage: "plus") }
                        .accessibilityIdentifier("add-torrent")
                }
                if !model.clients.isEmpty {
                    Button {
                        Task { await model.toggleThrottle() }
                    } label: {
                        Label(model.isThrottled ? "Throttled" : "Throttle", systemImage: "tortoise")
                            .symbolVariant(model.isThrottled ? .fill : .none)
                    }
                    .tint(model.isThrottled ? .orange : nil)
                    .disabled(model.isPending("throttle"))
                    .accessibilityIdentifier("throttle")
                }
                filterMenu
                sortMenu
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
        .confirmationDialog("Delete \(model.selected.count) torrents", isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
            Button("Delete torrents and files", role: .destructive) { Task { await model.bulk(.delete(deleteData: true)) } }
            Button("Delete torrents only", role: .destructive) { Task { await model.bulk(.delete(deleteData: false)) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleting?.name ?? "", isPresented: deletingShown, titleVisibility: .visible
        ) {
            if let torrent = deleting {
                Button("Delete torrent and files", role: .destructive) {
                    Task { await model.delete(torrent, deleteData: true) }
                }
                Button("Delete torrent only", role: .destructive) {
                    Task { await model.delete(torrent, deleteData: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("downloads")
    }

    /// Actions applied to the multi-selection, one call per client.
    @ViewBuilder var bulkBar: some View {
        Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Group {
            Button("Pause") { Task { await model.bulk(.pause) } }
            Button("Resume") { Task { await model.bulk(.resume) } }
            Button("Delete", role: .destructive) { confirmingBulkDelete = true }
        }
        .disabled(model.selected.isEmpty || model.isPending("bulk"))
    }

    var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(TorrentSort.allCases, id: \.self) { key in Text(key.label).tag(key) }
            }
            Picker("Direction", selection: $model.descending) {
                Text("Descending").tag(true)
                Text("Ascending").tag(false)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("sort")
    }

    var filterMenu: some View {
        Menu {
            if model.clients.count > 1 {
                ForEach(model.clients, id: \.self) { client in
                    Toggle(Services.label(client.rawValue), isOn: Binding(
                        get: { model.enabledClients.contains(client) },
                        set: { on in
                            if on { model.enabledClients.insert(client) } else { model.enabledClients.remove(client) }
                        }
                    ))
                }
                Divider()
            }
            Picker("State", selection: $model.stateFilter) {
                Text("All (\(model.loadedCount))").tag(String?.none)
                ForEach(model.states, id: \.self) { state in
                    Text(state).tag(String?.some(state))
                }
            }
        } label: {
            Label("Filters", systemImage: model.stateFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("filters")
    }

    var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    var actionFailed: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

extension Torrent: Identifiable {}

struct TorrentRow: View {
    let torrent: Torrent

    var details: String {
        var parts: [String] = []
        if let tracker = torrent.tracker { parts.append(tracker) }
        parts.append(Format.bytes(torrent.size))
        // total sent, not the current rate — the number that says whether a
        // torrent has actually given anything back
        var up = "↑\(Format.bytes(torrent.uploaded))"
        if let ratio = torrent.ratio { up += " (\(ratio.formatted(.number.precision(.fractionLength(2)))))" }
        parts.append(up)
        if torrent.dl_speed > 0 || torrent.ul_speed > 0 {
            parts.append("↓\(Format.speed(torrent.dl_speed)) ↑\(Format.speed(torrent.ul_speed))")
        }
        if torrent.eta != nil { parts.append(Format.eta(torrent.eta)) }
        if let error = torrent.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(torrent.name).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    StateBadge(state: torrent.state)
                    StateBadge(state: Services.label(torrent.client.rawValue))
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressBar(value: torrent.progress)
            }
            Text(Format.epochDay(torrent.added_on)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
