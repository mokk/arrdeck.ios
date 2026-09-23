import ArrdeckData
import SwiftUI

/// The Manage tab: a settings-style hub into the two libraries, the indexers,
/// the arrs' system pages and the connection settings. The PWA used sub-tabs;
/// on iOS a list of destinations reads better and leaves room to grow.
public struct ManageView: View {
    let model: DashboardModel
    let api: any ManageAPI & LibraryAPI
    let baseURL: URL
    let onSessionLost: @MainActor () -> Void

    public init(model: DashboardModel, api: any ManageAPI & LibraryAPI, baseURL: URL, onSessionLost: @escaping @MainActor () -> Void) {
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
    let baseURL: URL

    init(app: ArrApp, api: any ManageAPI & LibraryAPI, baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
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
                        NavigationLink(value: row.ref) {
                            HStack(spacing: 10) {
                                Poster(path: row.poster, baseURL: baseURL, width: 40, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        if let year = row.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                    HStack(spacing: 6) {
                                        StateBadge(state: model.app == .radarr ? row.status : (row.monitored ? "ok" : "paused"))
                                        WatchedDot(watched: model.watched(row))
                                        Text(stats(row)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("library-row")
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
            Menu {
                Picker("Sort by", selection: $model.sort) {
                    ForEach(LibrarySort.keys(for: model.app), id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Direction", selection: $model.descending) {
                    Text("Ascending").tag(false)
                    Text("Descending").tag(true)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    func stats(_ row: LibraryRow) -> String {
        if model.app == .sonarr {
            return "\(row.episodeFiles ?? 0)/\(row.episodes ?? 0) episodes · \(Format.bytes(row.sizeOnDisk))"
        }
        return Format.bytes(row.sizeOnDisk)
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
