import ArrdeckData
import SwiftUI

/// The Manage tab: a settings-style hub into the two libraries, the indexers,
/// the arrs' system pages and the connection settings. The PWA used sub-tabs;
/// on iOS a list of destinations reads better and leaves room to grow.
public struct ManageView: View {
    let model: DashboardModel
    let api: any ManageAPI & LibraryAPI & ExtrasAPI
    let baseURL: URL
    let onSessionLost: @MainActor () -> Void

    public init(model: DashboardModel, api: any ManageAPI & LibraryAPI & ExtrasAPI, baseURL: URL, onSessionLost: @escaping @MainActor () -> Void) {
        self.model = model
        self.api = api
        self.baseURL = baseURL
        self.onSessionLost = onSessionLost
    }

    var hasPlex: Bool { model.has("plex") }

    public var body: some View {
        List {
            Section("Library") {
                if model.has("radarr") {
                    NavigationLink {
                        LibraryListView(app: .radarr, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
                    } label: { Label("Movies", systemImage: "film") }
                    .accessibilityIdentifier("manage-movies")
                }
                if model.has("sonarr") {
                    NavigationLink {
                        LibraryListView(app: .sonarr, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
                    } label: { Label("Series", systemImage: "tv") }
                    .accessibilityIdentifier("manage-series")
                }
            }
            if model.has("prowlarr") || model.hasArr {
                Section("Services") {
                    if model.has("prowlarr") {
                        NavigationLink {
                            IndexersView(api: api, onSessionLost: onSessionLost)
                        } label: { Label("Indexers", systemImage: "antenna.radiowaves.left.and.right") }
                        .accessibilityIdentifier("manage-indexers")
                    }
                    NavigationLink {
                        SystemView(configured: model.configured, api: api, onSessionLost: onSessionLost)
                    } label: { Label("System", systemImage: "gearshape.2") }
                    .accessibilityIdentifier("manage-system")
                }
            }
            Section {
                NavigationLink {
                    ServicesView(api: api, onSessionLost: onSessionLost)
                } label: { Label("Connections", systemImage: "link") }
                .accessibilityIdentifier("manage-connections")
            } footer: {
                Text("Where arrdeck finds each service. Changing these affects every screen.")
            }
        }
        .dashboardListStyle()
        .navigationTitle("Manage")
        .navigationDestination(for: MediaRef.self) { ref in
            switch ref {
            case let .movie(id):
                MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            case let .series(id):
                SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            }
        }
        .accessibilityIdentifier("manage")
    }
}

struct LibraryListView: View {
    @State private var model: LibraryListModel
    @State private var confirmingBulkDelete = false
    let baseURL: URL

    init(app: ArrApp, api: any ManageAPI & LibraryAPI & ExtrasAPI, baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        _model = State(initialValue: LibraryListModel(app: app, api: api, hasPlex: hasPlex, onSessionLost: onSessionLost))
    }

    var body: some View {
        List {
            switch model.rows {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case .loaded:
                Section {
                    if model.shown.isEmpty { EmptyNote("No matches") }
                    ForEach(model.shown) { row in
                        LibraryRowView(row: row, model: model, baseURL: baseURL)
                    }
                } header: {
                    Text("\(model.shown.count) of \(model.rows.value?.count ?? 0)")
                }
            }
        }
        .dashboardListStyle()
        .searchable(text: $model.query, prompt: model.app == .radarr ? "Filter movies…" : "Filter series…")
        .navigationTitle(model.app == .radarr ? "Movies" : "Series")
        .toolbar {
            if model.selecting {
                ToolbarItemGroup(placement: .bulkBar) { LibraryBulkBar(model: model) { confirmingBulkDelete = true } }
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(model.selecting ? "Done" : "Select") { model.selecting.toggle() }
                tagMenu
                sortMenu
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Delete \(model.selected.count) titles", isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
            Button("Delete from library and disk", role: .destructive) { Task { await model.bulk(.delete(deleteFiles: true)) } }
            Button("Remove from library only", role: .destructive) { Task { await model.bulk(.delete(deleteFiles: false)) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    @ViewBuilder var tagMenu: some View {
        if !model.tags.isEmpty {
            Menu {
                Picker("Tag", selection: $model.tag) {
                    Text("All").tag(Int?.none)
                    ForEach(model.tags, id: \.id) { tag in Text(tag.label).tag(Int?.some(tag.id)) }
                }
            } label: {
                Label("Tags", systemImage: model.tag == nil ? "tag" : "tag.fill")
            }
        }
    }

    var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(LibrarySort.keys(for: model.app), id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            Picker("Direction", selection: $model.descending) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

struct LibraryRowView: View {
    let row: LibraryRow
    let model: LibraryListModel
    let baseURL: URL

    var badge: String { model.app == .radarr ? row.status : (row.monitored ? "ok" : "paused") }

    var stats: String {
        if model.app == .sonarr {
            return "\(row.episodeFiles ?? 0)/\(row.episodes ?? 0) episodes · \(Format.bytes(row.sizeOnDisk))"
        }
        return Format.bytes(row.sizeOnDisk)
    }

    var content: some View {
        HStack(spacing: 10) {
            if model.selecting {
                Image(systemName: model.selected.contains(row.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selected.contains(row.id) ? Color.accentColor : Color.secondary)
            }
            Poster(path: row.poster, baseURL: baseURL, width: 40, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let year = row.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    StateBadge(state: badge)
                    WatchedDot(watched: model.watched(row))
                    Text(stats).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        if model.selecting {
            Button { model.toggleSelection(row) } label: { content }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: row.ref) { content }
                .accessibilityIdentifier("library-row")
        }
    }
}

/// Monitor, profile, tags, search and delete for the selection.
struct LibraryBulkBar: View {
    let model: LibraryListModel
    let confirmDelete: () -> Void

    var body: some View {
        Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Menu("Edit") {
            Button("Monitor") { Task { await model.bulk(.monitor(true)) } }
            Button("Unmonitor") { Task { await model.bulk(.monitor(false)) } }
            if let profiles = model.options?.quality_profiles, !profiles.isEmpty {
                Menu("Quality profile") {
                    ForEach(profiles, id: \.id) { profile in
                        Button(profile.name) { Task { await model.bulk(.profile(profile.id)) } }
                    }
                }
            }
            if !model.tags.isEmpty {
                Menu("Add tag") {
                    ForEach(model.tags, id: \.id) { tag in Button(tag.label) { Task { await model.bulk(.tag(tag.id, add: true)) } } }
                }
                Menu("Remove tag") {
                    ForEach(model.tags, id: \.id) { tag in Button(tag.label) { Task { await model.bulk(.tag(tag.id, add: false)) } } }
                }
            }
        }
        .disabled(model.selected.isEmpty || model.busy)
        Button("Search") { Task { await model.bulk(.search) } }
            .disabled(model.selected.isEmpty || model.busy)
        Button("Delete", role: .destructive, action: confirmDelete)
            .disabled(model.selected.isEmpty || model.busy)
    }
}

struct IndexersView: View {
    @State private var model: IndexersModel

    init(api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: IndexersModel(api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        List {
            switch model.indexers {
            case .loading:
                LoadingRow()
            case let .failed(reason):
                ErrorNote(reason)
            case .loaded:
                ForEach(model.sorted, id: \.id) { indexer in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(indexer.name ?? "").font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                StateBadge(state: indexer.enable == true ? "enabled" : "disabled")
                                Text([indexer._protocol, indexer.privacy].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let verdict = model.tested[indexer.id] {
                                    StateBadge(state: verdict ? "ok" : "failed")
                                }
                            }
                        }
                        Spacer()
                        Button("Test") { Task { await model.test(indexer) } }
                            .buttonStyle(.bordered).controlSize(.small)
                        Toggle("Enabled", isOn: Binding(
                            get: { indexer.enable == true },
                            set: { on in Task { await model.setEnabled(indexer, on) } }
                        ))
                        .labelsHidden()
                    }
                    .disabled(model.pending.contains(indexer.id))
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle("Indexers")
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }
}
