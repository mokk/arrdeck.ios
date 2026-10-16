import ArrdeckData
import ArrdeckKit
import SwiftUI

/// The Manage tab: a settings-style hub into the two libraries, the indexers,
/// the arrs' system pages and the services' connections. The PWA used sub-tabs;
/// on iOS a list of destinations reads better and leaves room to grow.
public struct ManageView: View {
    let model: DashboardModel
    let api: any LibraryPageAPI & IndexerAddAPI & HistoryAPI & DownloadsAPI & CalendarAPI
    let baseURL: URL
    let profileName: String
    let onSessionLost: @MainActor () -> Void
    let onSwitchProfile: () -> Void

    public init(
        model: DashboardModel,
        api: any LibraryPageAPI & IndexerAddAPI & HistoryAPI & DownloadsAPI & CalendarAPI,
        baseURL: URL, profileName: String,
        onSessionLost: @escaping @MainActor () -> Void,
        onSwitchProfile: @escaping () -> Void
    ) {
        self.model = model
        self.api = api
        self.baseURL = baseURL
        self.profileName = profileName
        self.onSessionLost = onSessionLost
        self.onSwitchProfile = onSwitchProfile
    }

    var hasPlex: Bool { model.has("plex") }

    public var body: some View {
        List {
            Section("Profile") {
                Button(action: onSwitchProfile) {
                    HStack {
                        Label(profileName, systemImage: "person.crop.circle")
                        Spacer()
                        Text("Switch").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("profiles")
            }
            if let expiry = ServerView.expiry {
                Section {
                    HStack {
                        Label("Signature expires", systemImage: "clock.badge.exclamationmark")
                        Spacer()
                        Text(expiry, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                            .foregroundStyle(SigningExpiry.isClose(expiry) ? Color.warning : .secondary)
                    }
                } footer: {
                    Text("A free developer signature lasts seven days. In its last two days, reinstalling from your Mac renews it for another seven.")
                }
            }
            Section {
                NavigationLink {
                    DisplaySettingsView(configured: model.configured)
                } label: { Label("Display", systemImage: "paintpalette") }
                .accessibilityIdentifier("settings-display")
            }
            Section("More") {
                if model.has("prowlarr") {
                    NavigationLink {
                        PopularView(api: api, onSessionLost: onSessionLost)
                    } label: { Label("Popular releases", systemImage: "flame") }
                }
                if hasPlex, let watching = api as? any WatchingAPI {
                    NavigationLink {
                        StatsScreen(api: watching, baseURL: baseURL)
                    } label: { Label("Statistics", systemImage: "chart.line.uptrend.xyaxis") }
                    .accessibilityIdentifier("manage-stats")
                }
                NavigationLink {
                    DashboardView(model: model, baseURL: baseURL, api: api, onSessionLost: onSessionLost)
                        .navigationTitle("Overview")
                        .pageTitle()
                } label: { Label("Overview", systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("overview")
                if model.hasArr, let cleanup = api as? any CleanupAPI {
                    NavigationLink {
                        CleanupView(api: cleanup, baseURL: baseURL)
                    } label: { Label("Cleanup", systemImage: "eraser") }
                }
                if model.hasArr {
                    NavigationLink {
                        WantedView(api: api, apps: ArrApp.allCases.filter { model.has($0.rawValue) },
                                   baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
                    } label: { Label("Wanted", systemImage: "magnifyingglass.circle") }
                }
            }
            if model.has("prowlarr") || model.hasArr || model.has("bazarr") {
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
                    if let tools = api as? any ToolsAPI {
                        NavigationLink {
                            ExclusionsView(api: tools)
                        } label: { Label("Exclusions", systemImage: "nosign") }
                        let parseApps = [ArrApp.radarr, .sonarr].filter { model.has($0.rawValue) }
                        if !parseApps.isEmpty {
                            NavigationLink {
                                ParseView(api: tools, apps: parseApps)
                            } label: { Label("Release name tester", systemImage: "flask") }
                        }
                    }
                    if model.has("bazarr"), let subtitles = api as? any SubtitleToolsAPI {
                        NavigationLink {
                            SubtitleToolsView(api: subtitles)
                        } label: { Label("Subtitles", systemImage: "captions.bubble") }
                        .accessibilityIdentifier("manage-subtitles")
                    }
                }
            }
            Section {
                NavigationLink {
                    ServicesView(api: api, onSessionLost: onSessionLost)
                } label: { Label("Connections", systemImage: "link") }
                .accessibilityIdentifier("manage-connections")
            } footer: {
                Text("Where arrdeck finds each service, kept on this device. Away from home they need to be reachable from where you are, through a VPN such as Tailscale.")
            }
        }
        .dashboardListStyle()
        .chromePage()
        .navigationTitle("Settings")
        .pageTitle()
        .navigationDestination(for: MediaRef.self) { ref in
            TitleDetail(ref: ref, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
        }
        .accessibilityIdentifier("settings")
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
    @State private var adding = false
    let api: any ManageAPI & IndexerAddAPI
    let onSessionLost: @MainActor () -> Void

    init(api: any ManageAPI & IndexerAddAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
        _model = State(initialValue: IndexersModel(api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        List {
            ListPageHeading(title: String(localized: "Indexers"))
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
        .chromePage()
        .navigationTitle("Indexers")
        .pageTitle()
        .chromeActions {
            Button { adding = true } label: { Label("Add indexer", systemImage: "plus") }
                .accessibilityIdentifier("add-indexer")
        }
        .sheet(isPresented: $adding) {
            AddIndexerSheet(api: api, onSessionLost: onSessionLost) {
                adding = false
                Task { await model.load() }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }
}
