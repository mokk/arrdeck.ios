import ArrdeckData
import SwiftUI

/// What the import sheet is opened on, and the name to show above the files.
struct ImportJob: Identifiable {
    let source: ImportSource
    let title: String
    var id: String { source.id }
}

/// Everything the arr found in a stuck download, or in a finished torrent no
/// arr is tracking, including the files it refused and why — so a rejection
/// is read and overridden rather than guessed at. One import per sheet: the
/// files it takes are gone from the list afterwards.
struct ImportSheet: View {
    let job: ImportJob
    let library: (any ManageAPI)?
    let details: (any LibraryAPI)?
    let music: (any MusicLibraryAPI)?
    /// Called once the arr says the import is done, to refresh what opened it.
    let onFinished: () -> Void
    let dismiss: () -> Void
    @State private var model: ImportModel?
    @State private var path: [ImportRoute] = []
    // Its own dialog host: the shell's sits under this sheet and cannot
    // present over it. An import always asks, whatever Settings says.
    @State private var confirm = ConfirmCenter()

    /// `api` is whatever the presenting screen holds; the live client does
    /// all of them, a server without manual import shows a note instead.
    init(job: ImportJob, api: any Sendable,
         onFinished: @escaping () -> Void = {}, dismiss: @escaping () -> Void) {
        self.job = job
        library = api as? any ManageAPI
        details = api as? any LibraryAPI
        music = api as? any MusicLibraryAPI
        self.onFinished = onFinished
        self.dismiss = dismiss
        _model = State(initialValue: (api as? any ManualImportAPI).map {
            ImportModel(source: job.source, api: $0)
        })
    }

    var title: String {
        switch job.source {
        case let .torrent(app, _, _): String(localized: "Import into \(Services.label(app.rawValue))")
        case .queue: String(localized: "Manual import")
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    ImportList(model: model, title: job.title, confirm: confirm, path: $path)
                        .task { await model.load() }
                        .onChange(of: model.finished) { _, done in if done { onFinished() } }
                        .navigationDestination(for: ImportRoute.self) { route in
                            destination(route, model: model)
                        }
                } else {
                    List { ErrorNote(String(localized: "Files can't be imported by hand here.")) }
                }
            }
            .navigationTitle(title)
            .toolbar { Button("Done") { dismiss() } }
        }
        .outsideChrome()
        .confirmDialog(confirm)
    }

    @ViewBuilder func destination(_ route: ImportRoute, model: ImportModel) -> some View {
        switch route {
        case let .target(candidate):
            ImportTargetPicker(app: model.app, candidate: candidate, library: library, music: music) { target in
                model.assign(target, to: candidate)
                path.removeAll()
            }
        case let .episodes(candidate, series, name):
            ImportEpisodePicker(candidate: candidate, series: series, name: name, details: details) { target in
                model.assign(target, to: candidate)
                path.removeAll()
            }
        case let .albums(candidate, artist, name):
            ImportAlbumPicker(candidate: candidate, artist: artist, name: name, music: music) { target in
                model.assign(target, to: candidate)
                path.removeAll()
            }
        case let .quality(candidate):
            ImportOverrideView(model: model, candidate: candidate)
        }
    }
}

/// The screens pushed inside the import sheet.
enum ImportRoute: Hashable {
    case target(ImportCandidate)
    case episodes(ImportCandidate, series: Int, name: String)
    case albums(ImportCandidate, artist: Int, name: String)
    case quality(ImportCandidate)
}

private struct ImportList: View {
    let model: ImportModel
    let title: String
    let confirm: ConfirmCenter
    @Binding var path: [ImportRoute]

    var body: some View {
        List {
            Section {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(3)
            }
            switch model.candidates {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                // the server's own sentence: not finished, already tracked by
                // an arr, or a folder the arr cannot see
                Section { ErrorNote(reason) }
            case let .loaded(list):
                if list.isEmpty {
                    Section { EmptyNote(String(localized: "The arr found nothing to import here.")) }
                } else {
                    files(list)
                    modeSection
                    actionSection
                }
            }
        }
        .dashboardListStyle()
        .disabled(model.starting)
    }

    @ViewBuilder func files(_ list: [ImportCandidate]) -> some View {
        Section {
            ForEach(list, id: \.path) { candidate in
                ImportCandidateRow(
                    candidate: candidate, model: model,
                    choose: { path.append(.target(candidate)) },
                    edit: { path.append(.quality(candidate)) }
                )
            }
        } header: {
            HStack {
                Text("Files (\(list.count))")
                Spacer()
                if list.contains(where: model.picks.ready), !model.started {
                    Button(model.picks.allPicked(list) ? String(localized: "Select none") : String(localized: "Select all")) {
                        model.picks.toggleAll(list)
                    }
                    .font(.caption).textCase(nil)
                }
            }
        } footer: {
            if model.albumForAll, !model.started {
                Text("The album you choose goes to every file that has none yet, and Lidarr works out which track each one is.")
            }
        }
    }

    var modeSection: some View {
        Section {
            Picker("Mode", selection: Binding(get: { model.picks.mode }, set: { model.picks.mode = $0 })) {
                ForEach(ImportMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.started)
            Text(model.picks.mode.explanation)
                .font(.caption)
                .foregroundStyle(model.picks.mode == .move ? Color.danger : .secondary)
        } header: {
            Text("How")
        }
    }

    var actionLabel: String {
        let count = model.chosenCount
        switch (model.picks.mode == .move, count == 1) {
        case (true, true): return String(localized: "Move 1 file")
        case (true, false): return String(localized: "Move \(count) files")
        case (false, true): return String(localized: "Import 1 file")
        case (false, false): return String(localized: "Import \(count) files")
        }
    }

    var actionSection: some View {
        Section {
            Button(role: model.picks.mode == .move ? .destructive : nil) {
                let app = Services.label(model.app.rawValue)
                // Asked even under "only before deleting": an import can
                // replace a file already in the library, and move takes the
                // files from the torrent client.
                ask(confirm, actionLabel, subject: "\(app) · \(model.picks.mode.explanation)", destructive: true, always: true) {
                    await model.start()
                }
            } label: {
                HStack {
                    Text(actionLabel).font(.body.weight(.semibold))
                    Spacer()
                    if model.starting { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.request == nil || model.started)
            .accessibilityIdentifier("import-run")
            if let error = model.actionError {
                ErrorNote(error)
            }
            // after three failed polls the wait is over; a spinner would lie
            if let outcome = model.outcome, model.actionError == nil {
                ImportOutcomeRow(outcome: outcome)
            }
        } footer: {
            if model.request == nil, !model.started {
                Text("Pick the files to import. A file the arr couldn't place needs a target first.")
            }
        }
    }
}

private struct ImportCandidateRow: View {
    let candidate: ImportCandidate
    let model: ImportModel
    let choose: () -> Void
    let edit: () -> Void

    var picked: Bool { model.picks.picked.contains(candidate.path) }
    var ready: Bool { model.picks.ready(candidate) }
    var target: ImportTarget? { model.picks.targets[candidate.path] }

    var matched: String {
        var parts: [String] = []
        if let title = candidate.title, !title.isEmpty { parts.append(title) }
        if let subtitle = candidate.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        parts.append(Format.bytes(candidate.size))
        return parts.joined(separator: " · ")
    }

    var detected: String {
        let quality = model.qualityName(candidate) ?? String(localized: "Unknown quality")
        return ([quality] + model.languageNames(candidate)).joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                // a file the arr couldn't place is pointed somewhere first
                if ready || picked { model.picks.toggle(candidate) } else { choose() }
            } label: {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.accent : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(model.started)
            .accessibilityLabel(picked ? String(localized: "Selected") : String(localized: "Not selected"))

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name ?? candidate.path).font(.subheadline).lineLimit(2)
                Text(matched).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                ForEach(candidate.rejections ?? [], id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(Color.warning)
                }
                if let target {
                    HStack(spacing: 8) {
                        Button(action: choose) { Text(verbatim: "→ \(target.label)") }.font(.caption)
                        Button(String(localized: "Use the arr's match")) { model.picks.clearTarget(candidate) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                } else if candidate.importable != true {
                    Button(String(localized: "Choose where this goes…"), action: choose)
                        .font(.caption).buttonStyle(.borderless)
                }
                Button(action: edit) {
                    HStack(spacing: 4) {
                        Text(detected)
                        Text("Change").underline()
                    }
                    .font(.caption)
                    .foregroundStyle(model.picks.isOverridden(candidate) ? Color.accent : .secondary)
                }
                .buttonStyle(.borderless)
            }
            .disabled(model.started)
        }
        .accessibilityIdentifier("import-candidate")
    }
}

private struct ImportOutcomeRow: View {
    let outcome: ImportOutcome

    var body: some View {
        switch outcome {
        case let .running(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Importing…").font(.subheadline)
                    // the arr's running commentary: "Processing file 2 of 3"
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case let .succeeded(text):
            VStack(alignment: .leading, spacing: 2) {
                Label(text, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Color.success)
                Text("Anything it still turned down shows in History.").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(text):
            Label(text, systemImage: "xmark.octagon.fill").font(.subheadline).foregroundStyle(Color.danger)
        }
    }
}

/// One file's quality and languages, for when the arr read the name wrong.
/// Starts from what the arr detected, and choosing that again is no change.
private struct ImportOverrideView: View {
    let model: ImportModel
    let candidate: ImportCandidate
    @State private var filter = ""

    var languages: [ImportChoice] {
        let all = model.options?.languages ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        List {
            Section { Text(candidate.name ?? candidate.path).font(.caption).foregroundStyle(.secondary) }
            if let options = model.options {
                Section("Quality") {
                    ForEach(options.qualities ?? [], id: \.id) { quality in
                        Button {
                            model.picks.setQuality(quality.id, for: candidate)
                        } label: {
                            HStack {
                                Text(quality.name).foregroundStyle(Color.primary)
                                if quality.id == candidate.quality_id {
                                    Text("detected").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.picks.qualityID(candidate) == quality.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accent)
                                }
                            }
                        }
                    }
                }
                // Readarr's and Lidarr's files carry no language: nothing to offer
                if !(options.languages ?? []).isEmpty {
                    Section("Languages") {
                        TextField(String(localized: "Filter languages"), text: $filter)
                        ForEach(languages, id: \.id) { language in
                            Button {
                                model.picks.toggleLanguage(language.id, for: candidate)
                            } label: {
                                HStack {
                                    Text(language.name).foregroundStyle(Color.primary)
                                    if (candidate.language_ids ?? []).contains(language.id) {
                                        Text("detected").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.picks.languageIDs(candidate).contains(language.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(String(localized: "Use what the arr detected")) { model.picks.resetOverride(candidate) }
                        .disabled(!model.picks.isOverridden(candidate))
                }
            } else {
                Section { LoadingRow() }
            }
        }
        .dashboardListStyle()
        // Readarr's and Lidarr's files carry no language
        .navigationTitle((model.options?.languages ?? []).isEmpty ? String(localized: "Quality") : String(localized: "Quality & languages"))
    }
}

/// Points one file the arr couldn't place at a library entry. Movies and
/// books are a single choice; a show drills into its seasons and episodes,
/// an artist into their albums.
private struct ImportTargetPicker: View {
    let app: ArrApp
    let candidate: ImportCandidate
    let library: (any ManageAPI)?
    let music: (any MusicLibraryAPI)?
    let onPick: (ImportTarget) -> Void
    @State private var query = ""
    @State private var movies: Loadable<[LibraryMovie]> = .loading
    @State private var series: Loadable<[LibrarySeries]> = .loading
    @State private var books: Loadable<[LibraryBook]> = .loading
    @State private var artists: Loadable<[LibraryArtist]> = .loading

    var title: String {
        switch app {
        case .radarr: String(localized: "Choose a movie")
        case .sonarr: String(localized: "Choose a show")
        case .readarr: String(localized: "Choose a book")
        case .lidarr: String(localized: "Choose an artist")
        }
    }

    var prompt: String {
        app == .lidarr ? String(localized: "Filter artists") : String(localized: "Filter the library")
    }

    var body: some View {
        List {
            Section { Text(candidate.name ?? candidate.path).font(.caption).foregroundStyle(.secondary) }
            Section {
                switch app {
                case .radarr: movieRows
                case .sonarr: seriesRows
                case .readarr: bookRows
                case .lidarr: artistRows
                }
            }
        }
        .dashboardListStyle()
        .searchable(text: $query, prompt: prompt)
        .navigationTitle(title)
        .task { await load() }
    }

    @ViewBuilder var movieRows: some View {
        switch movies {
        case .loading: LoadingRow()
        case let .failed(reason): ErrorNote(reason)
        case let .loaded(all):
            let shown = ImportTargetSearch.movies(all, query: query)
            if shown.isEmpty { EmptyNote(String(localized: "No matches")) }
            ForEach(shown, id: \.id) { movie in
                let name = movie.title ?? ""
                let label = movie.year.map { "\(name) (\($0))" } ?? name
                Button {
                    onPick(.movie(movie.id, label: label))
                } label: {
                    PickRow(title: name, detail: movie.year.map(String.init))
                }
            }
        }
    }

    @ViewBuilder var seriesRows: some View {
        switch series {
        case .loading: LoadingRow()
        case let .failed(reason): ErrorNote(reason)
        case let .loaded(all):
            let shown = ImportTargetSearch.series(all, query: query)
            if shown.isEmpty { EmptyNote(String(localized: "No matches")) }
            ForEach(shown, id: \.id) { show in
                NavigationLink(value: ImportRoute.episodes(candidate, series: show.id, name: show.title ?? "")) {
                    PickRow(title: show.title ?? "", detail: show.year.map(String.init))
                }
            }
        }
    }

    @ViewBuilder var bookRows: some View {
        switch books {
        case .loading: LoadingRow()
        case let .failed(reason): ErrorNote(reason)
        case let .loaded(all):
            let shown = ImportTargetSearch.books(all, query: query)
            if shown.isEmpty { EmptyNote(String(localized: "No matches")) }
            ForEach(shown, id: \.id) { book in
                Button {
                    onPick(.book(book.id, label: [book.title, book.author].compactMap { $0 }.joined(separator: " — ")))
                } label: {
                    PickRow(title: book.title ?? "", detail: book.author)
                }
            }
        }
    }

    @ViewBuilder var artistRows: some View {
        switch artists {
        case .loading: LoadingRow()
        case let .failed(reason): ErrorNote(reason)
        case let .loaded(all):
            let shown = ImportTargetSearch.artists(all, query: query)
            if shown.isEmpty { EmptyNote(String(localized: "No matches")) }
            ForEach(shown, id: \.id) { artist in
                let count = artist.album_count ?? 0
                NavigationLink(value: ImportRoute.albums(candidate, artist: artist.id, name: artist.name ?? "")) {
                    PickRow(title: artist.name ?? "", detail: count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums"))
                }
            }
        }
    }

    func load() async {
        func describe(_ error: any Error) -> String { (error as? APIError)?.description ?? error.localizedDescription }
        let unavailable = String(localized: "The library isn't available.")
        if app == .lidarr {
            guard let music else { artists = .failed(unavailable); return }
            do { artists = .loaded(try await music.libraryArtists()) } catch { artists = .failed(describe(error)) }
            return
        }
        guard let library else {
            movies = .failed(unavailable); series = .failed(unavailable); books = .failed(unavailable)
            return
        }
        switch app {
        case .radarr:
            do { movies = .loaded(try await library.libraryMovies()) } catch { movies = .failed(describe(error)) }
        case .sonarr:
            do { series = .loaded(try await library.librarySeries()) } catch { series = .failed(describe(error)) }
        case .readarr:
            do { books = .loaded(try await library.libraryBooks()) } catch { books = .failed(describe(error)) }
        case .lidarr: ()   // asked of the music library above
        }
    }
}

/// One artist's albums, newest first. Which track each file is, Lidarr
/// works out itself once it knows the album.
private struct ImportAlbumPicker: View {
    let candidate: ImportCandidate
    let artist: Int
    let name: String
    let music: (any MusicLibraryAPI)?
    let onPick: (ImportTarget) -> Void
    @State private var query = ""
    @State private var albums: Loadable<[LibraryAlbum]> = .loading

    func detail(_ album: LibraryAlbum) -> String {
        let tracks = album.track_count ?? 0
        let count = tracks == 1 ? String(localized: "1 track") : String(localized: "\(tracks) tracks")
        return [album.year.map(String.init), album.album_type, count].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        List {
            Section { Text(candidate.name ?? candidate.path).font(.caption).foregroundStyle(.secondary) }
            Section {
                switch albums {
                case .loading: LoadingRow()
                case let .failed(reason): ErrorNote(reason)
                case let .loaded(all):
                    let shown = ImportTargetSearch.albums(all, query: query)
                    if shown.isEmpty { EmptyNote(String(localized: "No matches")) }
                    ForEach(shown, id: \.id) { album in
                        Button {
                            onPick(.album(album.id, label: ImportTargetSearch.albumLabel(artist: name, album: album)))
                        } label: {
                            PickRow(title: album.title ?? "", detail: detail(album))
                        }
                    }
                }
            } header: {
                Text("Choose an album")
            }
        }
        .dashboardListStyle()
        .searchable(text: $query, prompt: String(localized: "Filter albums"))
        .navigationTitle(name)
        .task { await load() }
    }

    func load() async {
        guard let music else {
            albums = .failed(String(localized: "The library isn't available."))
            return
        }
        do {
            albums = .loaded(try await music.artistAlbums(artist))
        } catch {
            albums = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }
}

private struct PickRow: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.primary).lineLimit(2)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

/// A show's season, then the episodes the file holds — several for a
/// double episode.
private struct ImportEpisodePicker: View {
    let candidate: ImportCandidate
    let series: Int
    let name: String
    let details: (any LibraryAPI)?
    let onPick: (ImportTarget) -> Void
    @State private var seasons: Loadable<[Int]> = .loading
    @State private var season: Int?
    @State private var episodes: Loadable<[Episode]> = .loading
    @State private var chosen: Set<Int> = []

    var body: some View {
        List {
            Section { Text(candidate.name ?? candidate.path).font(.caption).foregroundStyle(.secondary) }
            switch seasons {
            case .loading: Section { LoadingRow() }
            case let .failed(reason): Section { ErrorNote(reason) }
            case let .loaded(numbers):
                Section {
                    Picker("Season", selection: Binding(get: { season ?? numbers.first ?? 0 }, set: { pick($0) })) {
                        ForEach(numbers, id: \.self) { number in
                            Text(number == 0 ? String(localized: "Specials") : String(localized: "Season \(number)")).tag(number)
                        }
                    }
                }
                Section("Episodes") {
                    switch episodes {
                    case .loading: LoadingRow()
                    case let .failed(reason): ErrorNote(reason)
                    case let .loaded(list):
                        if list.isEmpty { EmptyNote(String(localized: "No episodes")) }
                        ForEach(list, id: \.id) { episode in
                            Button {
                                if chosen.remove(episode.id) == nil { chosen.insert(episode.id) }
                            } label: {
                                HStack {
                                    Image(systemName: chosen.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(episode.id) ? Color.accent : Color.secondary)
                                    Text(String(format: "E%02d", episode.episode)).font(.subheadline.monospacedDigit())
                                        .foregroundStyle(Color.primary)
                                    Text(episode.title ?? "").font(.subheadline).foregroundStyle(Color.primary).lineLimit(1)
                                    Spacer()
                                    if episode.has_file == true { StateBadge(state: "downloaded") }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(chosen.count > 1 ? String(localized: "Use \(chosen.count) episodes") : String(localized: "Use this episode")) {
                        let list = episodes.value ?? []
                        let numbers = list.filter { chosen.contains($0.id) }.map(\.episode)
                        let label = ImportTargetSearch.episodeLabel(series: name, season: season ?? 0, episodes: numbers)
                        onPick(.episodes(series: series, ids: list.filter { chosen.contains($0.id) }.map(\.id), label: label))
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle(name)
        .task { await loadSeasons() }
    }

    func describe(_ error: any Error) -> String { (error as? APIError)?.description ?? error.localizedDescription }

    func loadSeasons() async {
        guard let details else {
            seasons = .failed(String(localized: "The library isn't available."))
            return
        }
        do {
            // regular seasons newest first, where a stray download most often
            // belongs; specials last
            let numbers = try await details.seriesDetail(series).seasons.map(\.number)
            let ordered = numbers.filter { $0 > 0 }.sorted(by: >) + numbers.filter { $0 == 0 }
            seasons = .loaded(ordered)
            if let first = ordered.first { pick(first) }
        } catch {
            seasons = .failed(describe(error))
        }
    }

    func pick(_ number: Int) {
        guard number != season else { return }
        season = number
        chosen = []
        episodes = .loading
        Task {
            guard let details else { return }
            do {
                let list = try await details.episodes(series: series, season: number)
                guard season == number else { return }   // another season was picked meanwhile
                episodes = .loaded(list.sorted { $0.episode < $1.episode })
            } catch {
                guard season == number else { return }
                episodes = .failed(describe(error))
            }
        }
    }
}
