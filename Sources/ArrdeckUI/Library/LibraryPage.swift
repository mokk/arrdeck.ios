import ArrdeckData
import SwiftUI

/// Movies or Shows: the library as cards, with sort, search and add in the
/// bar. Nothing else on the page — the cards are the page.
public struct LibraryPage: View {
    @State private var model: LibraryListModel
    @State private var adding = false
    @State private var diagnosing: LibraryRow?
    @State private var confirmingBulkDelete = false
    let app: ArrApp
    let dashboard: DashboardModel
    let api: any ManageAPI & LibraryAPI & ExtrasAPI & DiscoverAPI & WantedAPI
    let baseURL: URL
    let onSessionLost: @MainActor () -> Void

    public init(
        app: ArrApp, dashboard: DashboardModel,
        api: any ManageAPI & LibraryAPI & ExtrasAPI & DiscoverAPI & WantedAPI,
        baseURL: URL, onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.app = app
        self.dashboard = dashboard
        self.api = api
        self.baseURL = baseURL
        self.onSessionLost = onSessionLost
        _model = State(initialValue: LibraryListModel(app: app, api: api, hasPlex: dashboard.has("plex"), onSessionLost: onSessionLost))
    }

    var title: String {
        switch app {
        case .radarr: String(localized: "Movies")
        case .sonarr: String(localized: "Shows")
        case .readarr: String(localized: "Books")
        }
    }

    var prompt: String {
        switch app {
        case .radarr: String(localized: "Search movies")
        case .sonarr: String(localized: "Search shows")
        case .readarr: String(localized: "Search books")
        }
    }

    public var body: some View {
        ScrollView {
            switch model.rows {
            case .loading:
                LoadingRow().padding()
            case let .failed(reason):
                ErrorNote(reason).padding()
            case .loaded:
                if model.shown.isEmpty {
                    EmptyNote("No matches").padding()
                }
                LibraryGrid(model: model, baseURL: baseURL, progress: dashboard.queueProgress) { diagnosing = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.grouped)
        .navigationTitle(title)
        .searchable(text: $model.query, placement: .alwaysVisible, prompt: Text(prompt))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.selecting {
                    Button("Done") { model.selecting = false }
                } else {
                    sortMenu
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }
                        .accessibilityIdentifier("library-add")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selecting { BulkBarChrome { LibraryBulkBar(model: model) { confirmingBulkDelete = true } } }
        }
        .navigationDestination(for: MediaRef.self) { ref in
            switch ref {
            case let .movie(id):
                MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: dashboard.has("plex"), onSessionLost: onSessionLost)
            case let .series(id):
                SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: dashboard.has("plex"), onSessionLost: onSessionLost)
            case let .book(id):
                BookDetailView(id: id, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
            }
        }
        .sheet(isPresented: $adding) {
            AddView(configured: dashboard.configured, api: api, baseURL: baseURL, hasPlex: dashboard.has("plex"),
                    fixed: addTab, onSessionLost: onSessionLost) {
                adding = false
                Task { await model.load() }
            }
        }
        .sheet(item: $diagnosing) { row in
            DiagnoseSheet(app: app, id: row.id, title: row.title, api: api) { diagnosing = nil }
        }
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
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("library-\(app.rawValue)")
    }

    var addTab: AddTab {
        switch app {
        case .radarr: .movies
        case .sonarr: .series
        case .readarr: .books
        }
    }

    var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(LibrarySort.keys(for: app), id: \.self) { key in Text(key.label).tag(key) }
            }
            Picker("Direction", selection: $model.descending) {
                Text("Ascending").tag(false)
                Text("Descending").tag(true)
            }
            if !model.tags.isEmpty {
                Picker("Tag", selection: $model.tag) {
                    Text("All tags").tag(Int?.none)
                    ForEach(model.tags, id: \.id) { tag in Text(tag.label).tag(Int?.some(tag.id)) }
                }
            }
            Divider()
            Button("Select…") { model.selecting = true }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("library-sort")
    }
}

struct LibraryGrid: View {
    let model: LibraryListModel
    let baseURL: URL
    let progress: [MediaRef: Double]
    let diagnose: (LibraryRow) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 110), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
            ForEach(model.shown) { row in
                LibraryCard(row: row, app: model.app, baseURL: baseURL, progress: progress[row.ref],
                            watched: model.watched(row), selected: model.selecting ? model.selected.contains(row.id) : nil)
                    .modifier(CardTap(row: row, model: model, diagnose: diagnose))
            }
        }
    }
}

/// Tap opens the title; in select mode it toggles; long-press offers the
/// per-card actions the PWA kept in a row of buttons.
struct CardTap: ViewModifier {
    let row: LibraryRow
    let model: LibraryListModel
    let diagnose: (LibraryRow) -> Void

    func body(content: Content) -> some View {
        if model.selecting {
            Button { model.toggleSelection(row) } label: { content }.buttonStyle(.plain)
        } else {
            NavigationLink(value: row.ref) { content }
                .buttonStyle(.plain)
                .contextMenu {
                    if row.dot == .wanted, model.app != .readarr {
                        Button { diagnose(row) } label: { Label("Why hasn't this arrived?", systemImage: "questionmark.circle") }
                    }
                    Button { model.selecting = true; model.toggleSelection(row) } label: { Label("Select", systemImage: "checkmark.circle") }
                }
                .accessibilityIdentifier("library-card")
        }
    }
}

struct LibraryCard: View {
    let row: LibraryRow
    let app: ArrApp
    let baseURL: URL
    let progress: Double?
    let watched: Watched?
    /// nil outside select mode; otherwise whether this card is chosen.
    let selected: Bool?

    var subtitle: String {
        switch app {
        case .radarr:
            let detail = row.dot == .complete ? Format.bytes(row.sizeOnDisk) : row.status
            return [row.year.map(String.init), detail].compactMap { $0 }.joined(separator: " · ")
        case .sonarr:
            return "\(row.episodeFiles ?? 0)/\(row.episodes ?? 0) · \(Format.bytes(row.sizeOnDisk))"
        case .readarr:
            return [row.author, row.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var dotColor: Color {
        switch row.dot {
        case .complete: .green
        case .wanted: .blue
        case .unmonitored: .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Poster(path: row.poster, baseURL: baseURL, width: 110, cornerRadius: 12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected ? Color.accentColor : Color.white)
                            .padding(6)
                    } else {
                        Circle().fill(dotColor).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).tint(.white)
                            .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            Text(row.title).font(.caption.weight(.semibold)).lineLimit(2).frame(height: 32, alignment: .top)
            HStack(spacing: 4) {
                WatchedDot(watched: watched)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

extension Color {
    /// The grouped background behind cards, on both platforms.
    static var grouped: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension SearchFieldPlacement {
    /// The field always shown under the title on iOS; macOS keeps its default.
    static var alwaysVisible: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}
