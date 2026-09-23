import ArrdeckData
import SwiftUI

/// Movies or Shows: the library as cards, with sort, search and add in the
/// bar. Nothing else on the page — the cards are the page.
public struct LibraryPage: View {
    @State private var model: LibraryListModel
    @State private var adding = false
    @State private var diagnosing: LibraryRow?
    @State private var deleting: LibraryRow?
    @State private var confirmingBulkDelete = false
    @AppStorage private var layout: LibraryLayout
    @AppStorage private var unmonitored: UnmonitoredMode
    let app: ArrApp
    let dashboard: DashboardModel
    let api: any LibraryPageAPI
    let baseURL: URL
    let onSessionLost: @MainActor () -> Void

    public init(
        app: ArrApp, dashboard: DashboardModel,
        api: any LibraryPageAPI,
        baseURL: URL, onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.app = app
        self.dashboard = dashboard
        self.api = api
        self.baseURL = baseURL
        self.onSessionLost = onSessionLost
        _model = State(initialValue: LibraryListModel(app: app, api: api, hasPlex: dashboard.has("plex"), onSessionLost: onSessionLost))
        _layout = AppStorage(wrappedValue: .posters, DisplayKeys.layout(app))
        _unmonitored = AppStorage(wrappedValue: .show, DisplayKeys.unmonitored(app))
    }

    /// The sorted rows minus the unmonitored ones when those are hidden.
    var visible: [LibraryRow] {
        unmonitored == .hide ? model.shown.filter { !$0.isUnmonitored } : model.shown
    }

    /// Letter → the first row filed under it, for the index strip.
    var letters: [(letter: String, id: Int)] {
        guard LibrarySorting.isAlphabetical(model.sort), !layout.ownsOrder else { return [] }
        var seen = Set<String>()
        return visible.compactMap { row in
            let letter = LibrarySorting.letter(row, sort: model.sort)
            return seen.insert(letter).inserted ? (letter, row.id) : nil
        }
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
        ScrollViewReader { proxy in
            ScrollView {
                switch model.rows {
                case .loading:
                    LoadingRow().padding()
                case let .failed(reason):
                    ErrorNote(reason).padding()
                case let .loaded(all):
                    if visible.isEmpty, layout != .collections {
                        emptyState(all: all)
                    }
                    if layout == .upNext {
                        UpNextList(rows: visible, baseURL: baseURL).padding(.horizontal, 16).padding(.bottom, 16)
                    } else if layout == .shelf {
                        ShelfView(rows: visible, query: model.query, api: api, baseURL: baseURL)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    } else if layout == .collections {
                        CollectionsLibraryList(api: api, baseURL: baseURL, query: model.query)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    } else {
                    LibraryGrid(model: model, rows: visible, layout: layout, dimUnmonitored: unmonitored == .dim,
                                baseURL: baseURL, progress: dashboard.queueProgress,
                                webURL: dashboard.webURLs[app.rawValue],
                                diagnose: { diagnosing = $0 }, delete: { deleting = $0 })
                        .padding(.leading, 16)
                        .padding(.trailing, letters.count >= LetterStrip.minimum ? 26 : 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if !model.selecting {
                    LetterStrip(letters: letters.map(\.letter)) { letter in
                        if let id = letters.first(where: { $0.letter == letter })?.id {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
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
            MediaDestination(ref: ref, api: api, baseURL: baseURL, hasPlex: dashboard.has("plex"), onSessionLost: onSessionLost)
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
        .confirmationDialog(deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { row in
            Button("Delete from library and disk", role: .destructive) { Task { await model.delete(row, deleteFiles: true) } }
            Button("Remove from library only", role: .destructive) { Task { await model.delete(row, deleteFiles: false) } }
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

    /// Why nothing shows, and the one thing that fixes it.
    @ViewBuilder
    func emptyState(all: [LibraryRow]) -> some View {
        if all.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "tray")
            } actions: {
                Button(addLabel) { adding = true }.buttonStyle(.bordered)
            }
        } else if model.shown.isEmpty, !model.query.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } actions: {
                Button("Clear search") { model.query = "" }.buttonStyle(.bordered)
            }
        } else if !model.shown.isEmpty {
            ContentUnavailableView {
                Label("Everything here is unmonitored, and unmonitored titles are hidden.", systemImage: "eye.slash")
            } actions: {
                Button("Show unmonitored") { unmonitored = .show }.buttonStyle(.bordered)
            }
        } else {
            EmptyNote("No matches").padding()
        }
    }

    var emptyTitle: String {
        switch app {
        case .radarr: String(localized: "No movies yet.")
        case .sonarr: String(localized: "No shows yet.")
        case .readarr: String(localized: "No books yet.")
        }
    }

    var addLabel: String {
        switch app {
        case .radarr: String(localized: "Add a movie")
        case .sonarr: String(localized: "Add a show")
        case .readarr: String(localized: "Add a book")
        }
    }

    var sortMenu: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                ForEach(LibraryLayout.options(for: app), id: \.self) { Text($0.label).tag($0) }
            }
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
    let rows: [LibraryRow]
    let layout: LibraryLayout
    let dimUnmonitored: Bool
    let baseURL: URL
    let progress: [MediaRef: Double]
    let webURL: URL?
    let diagnose: (LibraryRow) -> Void
    let delete: (LibraryRow) -> Void

    var body: some View {
        switch layout {
        case .posters:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 110), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(rows) { row in
                    LibraryCard(row: row, app: model.app, baseURL: baseURL, progress: progress[row.ref],
                                watched: model.watched(row), selected: model.selecting ? model.selected.contains(row.id) : nil)
                        .opacity(dimUnmonitored && row.isUnmonitored ? 0.4 : 1)
                        .modifier(tap(row))
                }
            }
        default:
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    LibraryListRow(row: row, app: model.app, baseURL: baseURL, details: layout == .details,
                                   progress: progress[row.ref], watched: model.watched(row),
                                   selected: model.selecting ? model.selected.contains(row.id) : nil)
                        .opacity(dimUnmonitored && row.isUnmonitored ? 0.5 : 1)
                        .modifier(tap(row))
                    if row.id != rows.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    func tap(_ row: LibraryRow) -> CardTap {
        CardTap(row: row, model: model, webURL: webURL, diagnose: diagnose, delete: delete)
    }
}

/// Tap opens the title; in select mode it toggles; long-press offers the
/// everyday actions without opening it, plus the way out to the arr and Plex.
struct CardTap: ViewModifier {
    let row: LibraryRow
    let model: LibraryListModel
    let webURL: URL?
    let diagnose: (LibraryRow) -> Void
    let delete: (LibraryRow) -> Void

    /// Each arr shows one title at /movie/<slug>, /series/<slug>, /book/<slug>.
    var arrURL: URL? {
        guard let webURL, let slug = row.slug else { return nil }
        let segment = switch row.ref {
        case .movie: "movie"
        case .series: "series"
        case .book: "book"
        }
        return webURL.appending(path: segment).appending(path: slug)
    }

    var appName: String {
        switch model.app {
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        case .readarr: "Readarr"
        }
    }

    func body(content: Content) -> some View {
        if model.selecting {
            Button { model.toggleSelection(row) } label: { content }.buttonStyle(.plain)
        } else {
            NavigationLink(value: row.ref) { content }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        Task { await model.setMonitored(row, !row.monitored) }
                    } label: {
                        row.monitored ? Label("Unmonitor", systemImage: "bookmark.slash") : Label("Monitor", systemImage: "bookmark")
                    }
                    Button { Task { await model.search(row) } } label: { Label("Search now", systemImage: "magnifyingglass") }
                    if row.dot == .wanted, model.app != .readarr {
                        Button { diagnose(row) } label: { Label("Why hasn't this arrived?", systemImage: "questionmark.circle") }
                    }
                    if let arrURL {
                        Link(destination: arrURL) { Label("Open in \(appName)", systemImage: "arrow.up.forward.app") }
                    }
                    if let plex = model.watched(row)?.url {
                        Link(destination: plex) { Label("Open in Plex", systemImage: "play.rectangle") }
                    }
                    Button { model.selecting = true; model.toggleSelection(row) } label: { Label("Select", systemImage: "checkmark.circle") }
                    Divider()
                    Button(role: .destructive) { delete(row) } label: { Label("Delete…", systemImage: "trash") }
                }
                .accessibilityIdentifier("library-card")
        }
    }
}

/// A row of the list and details layouts.
struct LibraryListRow: View {
    let row: LibraryRow
    let app: ArrApp
    let baseURL: URL
    let details: Bool
    let progress: Double?
    let watched: Watched?
    let selected: Bool?

    var subtitle: String {
        switch app {
        case .radarr: row.year.map(String.init) ?? ""
        case .sonarr: String(localized: "\(row.episodeFiles ?? 0)/\(row.episodes ?? 0) episodes")
        case .readarr: [row.author, row.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var facts: String {
        let size = row.sizeOnDisk > 0 ? Format.bytes(row.sizeOnDisk) : nil
        let rating = row.rating.map { "★ \($0.formatted(.number.precision(.fractionLength(1))))" }
        let parts: [String?] = switch app {
        case .radarr: [row.quality, size, rating]
        case .sonarr: [row.network, row.year.map(String.init), size]
        case .readarr: [row.seriesTitle, size]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Poster(path: row.poster, baseURL: baseURL, width: details ? 56 : 36, cornerRadius: details ? 8 : 6, title: row.title)
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.white)
                            .padding(3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    WatchedDot(watched: watched)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if details {
                    if !facts.isEmpty { Text(facts).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if let added = row.added {
                        Text("Added \(added.formatted(.relative(presentation: .named)))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if let progress {
                    ProgressView(value: progress).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Circle().fill(LibraryCard.color(row.dot)).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// The A–Z strip down the right edge under a title or author sort: tap a
/// letter or drag along the strip to jump, with a tick per letter.
struct LetterStrip: View {
    static let minimum = 4
    let letters: [String]
    let jump: (String) -> Void
    @State private var current: String?

    var body: some View {
        if letters.count >= Self.minimum {
            GeometryReader { geo in
                let height = min(CGFloat(letters.count) * 16, geo.size.height - 40)
                let step = height / CGFloat(letters.count)
                VStack(spacing: 0) {
                    ForEach(letters, id: \.self) { letter in
                        Text(letter).font(.system(size: min(11, step - 3), weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: step)
                    }
                }
                .frame(width: 22, height: height)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let index = min(max(Int(value.location.y / step), 0), letters.count - 1)
                    if letters[index] != current {
                        current = letters[index]
                        jump(letters[index])
                    }
                }.onEnded { _ in current = nil })
                .sensoryFeedback(.selection, trigger: current)
                .position(x: geo.size.width - 14, y: geo.size.height / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Jump to letter"))
                .accessibilityAdjustableAction { direction in
                    let index = letters.firstIndex(of: current ?? letters[0]) ?? 0
                    let next = direction == .increment ? min(index + 1, letters.count - 1) : max(index - 1, 0)
                    current = letters[next]
                    jump(letters[next])
                }
            }
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

    var dotColor: Color { Self.color(row.dot) }

    static func color(_ dot: LibraryRow.Dot) -> Color {
        switch dot {
        case .complete: .green
        case .wanted: .blue
        case .unmonitored: .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Poster(path: row.poster, baseURL: baseURL, width: 110, cornerRadius: 12, title: row.title, subtitle: subtitle)
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
    /// A card on the grouped background, on both platforms.
    static var card: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

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
