import ArrdeckData
import SwiftUI

/// The Add tab: search Radarr/Sonarr as you type, browse Overseerr's
/// popular titles while the box is empty, Radarr's collections, and raw
/// Prowlarr releases on submit.
public struct AddView: View {
    @State private var model: AddModel
    @State private var selected: SearchResult?
    @State private var collection: Collection?
    let api: any DiscoverAPI & LibraryAPI
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void

    public init(
        configured: Set<String>, api: any DiscoverAPI & LibraryAPI, baseURL: URL, hasPlex: Bool,
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
        _model = State(initialValue: AddModel(configured: configured, api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        Group {
            if model.tabs.isEmpty {
                ContentUnavailableView("No services configured", systemImage: "plus.circle",
                                       description: Text("Set up Radarr, Sonarr or Prowlarr under Manage → Connections."))
            } else {
                content
            }
        }
        .navigationTitle("Add")
        .searchable(text: $model.input, prompt: model.tab.prompt)
        .onSubmit(of: .search) { Task { await model.submit() } }
        .task { await model.load() }
        .sheet(item: $selected) { result in
            MediaSheet(result: result, api: api, baseURL: baseURL) {
                selected = nil
                Task { await model.submit() }
            }
        }
        .sheet(item: $collection) { item in
            CollectionSheet(collection: item, api: api, baseURL: baseURL) { collection = nil }
        }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("add")
    }

    var content: some View {
        List {
            if model.tabs.count > 1 {
                Section {
                    Picker("Tab", selection: $model.tab) {
                        ForEach(model.tabs, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            switch model.tab {
            case .movies, .series:
                if model.searching {
                    resultsSection(model.results, title: nil)
                } else if model.canDiscover {
                    resultsSection(model.discover[model.tab == .movies ? .movies : .series], title: model.tab == .movies ? "Popular movies" : "Popular series")
                } else {
                    Section { EmptyNote("Configure Overseerr under Manage → Connections to browse popular titles.") }
                }
            case .collections:
                collectionsSection
            case .releases:
                releasesSection
            }
        }
        .dashboardListStyle()
    }

    @ViewBuilder func resultsSection(_ state: Loadable<[SearchResult]>?, title: String?) -> some View {
        Section {
            switch state {
            case nil: EmptyView()
            case .loading?: LoadingRow()
            case let .failed(reason)?: ErrorNote(reason)
            case let .loaded(results)?:
                if results.isEmpty { EmptyNote("No matches") }
                PosterGrid(results: results, baseURL: baseURL) { selected = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }
        } header: {
            if let title { Text(title) }
        }
    }

    var collectionsSection: some View {
        Section {
            switch model.collections {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case .loaded:
                if model.shownCollections.isEmpty { EmptyNote("No matches") }
                ForEach(model.shownCollections, id: \.id) { item in
                    Button { collection = item } label: {
                        HStack(spacing: 10) {
                            Poster(path: item.poster, baseURL: baseURL, width: 36, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                                Text("\((item.movie_count ?? 0) - (item.missing_count ?? 0)) of \(item.movie_count ?? 0) movies")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(item.monitored == true ? "Unmonitor" : "Monitor") {
                                Task { await model.setCollectionMonitored(item, !(item.monitored ?? false)) }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(model.isPending("collection-\(item.id)"))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var releasesSection: some View {
        Section {
            switch model.releases {
            case nil: EmptyNote("Search Prowlarr for raw releases")
            case .loading?: LoadingRow()
            case let .failed(reason)?: ErrorNote(reason)
            case let .loaded(releases)?:
                if releases.isEmpty { EmptyNote("No releases found") }
                ForEach(releases, id: \.guid) { release in
                    ReleaseRow(
                        title: release.title,
                        details: releaseDetails(release),
                        grabbed: model.grabbed.contains(release.guid),
                        pending: model.isPending("grab-\(release.guid)")
                    ) { Task { await model.grab(release) } }
                }
            }
        }
    }

    func releaseDetails(_ release: Release) -> String {
        var parts = [release.indexer ?? "", Format.bytes(release.size), "\(release.seeders ?? 0) seeders"]
        if let age = release.age_days { parts.append("\(Int(age.rounded()))d old") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension SearchResult: Identifiable {
    public var id: String { "\(kind.rawValue)-\(remote_id)" }
}
extension Collection: Identifiable {}

struct ReleaseRow: View {
    let title: String
    let details: String
    let grabbed: Bool
    let pending: Bool
    let grab: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(grabbed ? "Grabbed" : "Grab", action: grab)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(grabbed || pending)
        }
    }
}

struct PosterGrid: View {
    let results: [SearchResult]
    let baseURL: URL
    let open: (SearchResult) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(results) { result in
                Button { open(result) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if result.poster != nil {
                            Poster(path: result.poster, baseURL: baseURL, width: 100, cornerRadius: 12)
                        } else {
                            Text(result.title).font(.caption2).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(width: 100, height: 150)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text(result.title).font(.caption.weight(.semibold)).lineLimit(2).frame(height: 32, alignment: .top)
                        HStack {
                            Text(result.year.map(String.init) ?? " ").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if result.in_library == true, result.has_file == true || result.monitored == true {
                                Text(result.has_file == true ? "Downloaded" : "Monitored")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(result.has_file == true ? .green : .blue)
                            }
                        }
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search-result")
            }
        }
    }
}

/// One sheet for both cases: add when not in library, edit when it is.
struct MediaSheet: View {
    @State private var model: MediaSheetModel
    @State private var confirmingDelete = false
    let baseURL: URL
    let dismiss: () -> Void

    init(result: SearchResult, api: any DiscoverAPI & LibraryAPI, baseURL: URL, dismiss: @escaping () -> Void) {
        self.baseURL = baseURL
        self.dismiss = dismiss
        _model = State(initialValue: MediaSheetModel(result: result, api: api, onSessionLost: {}))
    }

    var result: SearchResult { model.result }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailHero(poster: result.poster, baseURL: baseURL, overview: result.overview ?? "No description available.", links: result.externalLinks) {
                        Text(result.kind == .movie ? "Movie" : "Series")
                        if let year = result.year { Text("· \(year)") }
                        Text("· \(result.libraryState)")
                    }
                }
                if let error = model.error {
                    Section { ErrorNote(error) }
                }
                if result.in_library == true {
                    editSections
                } else {
                    addSections
                }
            }
            .navigationTitle(result.title)
            .toolbar { Button("Cancel") { dismiss() } }
            .task { await model.load() }
            .onChange(of: model.done) { _, done in if done { dismiss() } }
        }
    }

    @ViewBuilder var addSections: some View {
        Section {
            Picker("Quality profile", selection: $model.qualityProfile) {
                ForEach(model.options?.quality_profiles ?? [], id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
            }
            Picker("Root folder", selection: $model.rootFolder) {
                ForEach(model.options?.root_folders ?? [], id: \.id) { folder in
                    Text(folder.free_space.map { "\(folder.path) (\(Format.bytes($0)) free)" } ?? folder.path).tag(String?.some(folder.path))
                }
            }
        }
        Section {
            Button(model.busy ? "Adding…" : "Add & search") { Task { await model.add() } }
                .disabled(!model.canAdd)
                .accessibilityIdentifier("add-and-search")
        }
    }

    @ViewBuilder var editSections: some View {
        Section {
            Picker("Quality profile", selection: Binding(
                get: { model.qualityProfile ?? -1 },
                set: { id in if id != model.qualityProfile { Task { await model.setQualityProfile(id) } } }
            )) {
                ForEach(model.options?.quality_profiles ?? [], id: \.id) { Text($0.name).tag($0.id) }
            }
            if confirmingDelete {
                Button("Delete from library and disk", role: .destructive) { Task { await model.delete(deleteFiles: true) } }
                Button("Remove from library only", role: .destructive) { Task { await model.delete(deleteFiles: false) } }
                Button("Back") { confirmingDelete = false }
            } else {
                Button(result.monitored == true ? "Unmonitor" : "Monitor") { Task { await model.setMonitored(!(result.monitored ?? false)) } }
                Button("Search now") { Task { await model.search() } }
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            }
        }
        .disabled(model.busy)
    }
}

/// A Radarr collection: its movies, each opening the add/edit sheet.
struct CollectionSheet: View {
    let collection: Collection
    let api: any DiscoverAPI & LibraryAPI
    let baseURL: URL
    let dismiss: () -> Void
    @State private var detail: Loadable<CollectionDetail> = .loading
    @State private var selected: SearchResult?

    var body: some View {
        NavigationStack {
            List {
                switch detail {
                case .loading: Section { LoadingRow() }
                case let .failed(reason): Section { ErrorNote(reason) }
                case let .loaded(detail):
                    let movies = detail.movies ?? []
                    Section {
                        if let overview = detail.overview, !overview.isEmpty {
                            Text(overview).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("\(movies.filter { $0.in_library == true }.count) of \(movies.count) movies").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(movies) { movie in
                            Button { selected = movie } label: {
                                HStack(spacing: 10) {
                                    Poster(path: movie.poster, baseURL: baseURL, width: 36, cornerRadius: 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 4) {
                                            Text(movie.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                            if let year = movie.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                                        }
                                        Text(movie.libraryState.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(movie.has_file == true ? .green : (movie.in_library == true ? .blue : .secondary))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(collection.title ?? "…")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do { detail = .loaded(try await api.collectionDetail(collection.id)) }
                catch { detail = .failed((error as? APIError)?.description ?? error.localizedDescription) }
            }
            .sheet(item: $selected) { movie in
                MediaSheet(result: movie, api: api, baseURL: baseURL) { selected = nil }
            }
        }
    }
}
