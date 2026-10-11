import ArrdeckData
import SwiftUI

/// An artist as Lidarr keeps them: their picture and story, every album
/// their metadata profile allows grouped by type and monitored one by one,
/// Search, Refresh and rescan, Edit and Delete.
public struct ArtistDetailView: View {
    @State private var model: ArtistDetailModel
    @State private var editing = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.confirmCenter) private var confirmCenter
    let baseURL: URL

    public init(id: Int, api: any LibraryAPI & MusicLibraryAPI & ManageAPI, baseURL: URL,
                onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        _model = State(initialValue: ArtistDetailModel(id: id, api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.artist {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(artist):
                BackdropSection(path: artist.fanart, baseURL: baseURL)
                Section {
                    DetailHero(poster: artist.poster, baseURL: baseURL, overview: artist.overview, links: model.links,
                               ratings: artist.ratings ?? [], square: true) {
                        StateBadge(state: artist.state)
                        if let disambiguation = artist.disambiguation, !disambiguation.isEmpty { Text(disambiguation) }
                    }
                    Text(facts(artist)).font(.caption).foregroundStyle(.secondary)
                    if let genres = artist.genres, !genres.isEmpty { GenreChips(genres: genres) }
                }
                actions(artist)
                if (artist.albums ?? []).isEmpty {
                    Section { EmptyNote(String(localized: "Lidarr has no albums for this artist under its metadata profile.")) }
                }
                ForEach(model.groups, id: \.type) { group in
                    Section("\(group.label) (\(group.albums.count))") {
                        ForEach(group.albums, id: \.id) { album in
                            ArtistAlbumRow(album: album, baseURL: baseURL, model: model)
                        }
                    }
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle(model.artist.value?.name ?? "…")
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .sheet(isPresented: $editing) {
            if let artist = model.artist.value {
                ArtistEditSheet(artist: artist, model: model) { editing = false }
            }
        }
        // the two buttons are the confirmation, as on the other title pages
        .confirmationDialog("Delete", isPresented: $confirmingDelete, titleVisibility: .hidden) {
            Button("Delete from library and disk", role: .destructive) { Task { await model.delete(deleteFiles: true) } }
            Button("Remove from library only", role: .destructive) { Task { await model.delete(deleteFiles: false) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("artist-detail")
    }

    /// "5 albums · 21 of 94 tracks on disk · 17.8 MB"
    func facts(_ artist: ArtistDetail) -> String {
        var parts = [MusicLayout.albumCount(artist.album_count ?? 0)]
        if let total = artist.track_count, total > 0 {
            parts.append(MusicLayout.tracksOnDisk(have: artist.track_file_count ?? 0, total: total))
        }
        if let size = artist.size_on_disk, size > 0 { parts.append(Format.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    func actions(_ artist: ArtistDetail) -> some View {
        Section {
            let monitored = artist.monitored ?? false
            Button(monitored ? "Unmonitor" : "Monitor") {
                ask(confirmCenter, monitored ? String(localized: "Unmonitor") : String(localized: "Monitor"), subject: artist.name) {
                    await model.setMonitored(!monitored)
                }
            }
            // every monitored album of theirs that is missing or below cutoff
            Button("Search now") {
                ask(confirmCenter, String(localized: "Search now"), subject: artist.name) { await model.search() }
            }
            Button("Refresh and rescan") { Task { await model.refresh() } }
            Button("Edit…") { editing = true }
                .accessibilityIdentifier("artist-edit")
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        } footer: {
            if let notice = model.notice { Text(notice) }
        }
        .disabled(model.busy)
    }
}

/// One album on the artist's page: opens the album; the button beside it
/// monitors it or stops.
struct ArtistAlbumRow: View {
    let album: LibraryAlbum
    let baseURL: URL
    let model: ArtistDetailModel
    @Environment(\.confirmCenter) private var confirmCenter

    var details: String {
        ([MusicLayout.tracksOnDisk(have: album.track_file_count ?? 0, total: album.track_count ?? 0)] + (album.secondary_types ?? []))
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: MediaRef.album(album.id)) {
                HStack(spacing: 10) {
                    Poster(path: album.poster, baseURL: baseURL, width: 40, cornerRadius: 6, title: album.title, square: true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(album.title ?? "").font(.subheadline).lineLimit(2)
                            if let year = album.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        HStack(spacing: 6) {
                            StateBadge(state: album.state)
                            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            let monitored = album.monitored ?? false
            // an icon, so the album's title keeps the row's width
            Button {
                ask(confirmCenter, monitored ? String(localized: "Unmonitor") : String(localized: "Monitor"), subject: album.title) {
                    await model.setAlbumMonitored(album, !monitored)
                }
            } label: {
                Image(systemName: monitored ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(monitored ? Color.accent : Color.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(monitored ? String(localized: "Unmonitor") : String(localized: "Monitor"))
            .buttonStyle(.borderless)
            .disabled(model.busy)
        }
    }
}

/// Up to eight genres as chips, as the PWA shows them.
struct GenreChips: View {
    let genres: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(genres.prefix(8)), id: \.self) { genre in
                Text(genre)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

/// The artist's settings, as Lidarr's own Edit Artist has them. Only what
/// changed is sent.
struct ArtistEditSheet: View {
    let artist: ArtistDetail
    let model: ArtistDetailModel
    let dismiss: () -> Void
    @State private var qualityProfile: Int?
    @State private var metadataProfile: Int?
    @State private var newAlbums: NewAlbums
    @State private var path: String
    @State private var moveFiles = false
    @State private var tags: Set<Int>
    @State private var saving = false

    init(artist: ArtistDetail, model: ArtistDetailModel, dismiss: @escaping () -> Void) {
        self.artist = artist
        self.model = model
        self.dismiss = dismiss
        _qualityProfile = State(initialValue: artist.quality_profile_id)
        _metadataProfile = State(initialValue: artist.metadata_profile_id)
        _newAlbums = State(initialValue: NewAlbums(rawValue: artist.monitor_new_items ?? "") ?? .all)
        _path = State(initialValue: artist.path ?? "")
        _tags = State(initialValue: Set(artist.tags ?? []))
    }

    var changes: ArtistChanges {
        ArtistChanges.edit(artist, qualityProfile: qualityProfile, metadataProfile: metadataProfile, newAlbums: newAlbums,
                           path: path, moveFiles: moveFiles, tags: Array(tags).sorted())
    }

    var folderChanged: Bool {
        let folder = path.trimmingCharacters(in: .whitespaces)
        return !folder.isEmpty && folder != (artist.path ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality profile", selection: $qualityProfile) {
                        if qualityProfile == nil { Text("—").tag(Int?.none) }
                        ForEach(model.options?.quality_profiles ?? [], id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    Picker("Metadata profile", selection: $metadataProfile) {
                        if metadataProfile == nil { Text("—").tag(Int?.none) }
                        ForEach(model.options?.metadata_profiles ?? [], id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    Picker("New albums", selection: $newAlbums) {
                        ForEach(NewAlbums.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Folder") {
                    TextField("Folder", text: $path)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if folderChanged {
                        Toggle("Move the files to the new folder", isOn: $moveFiles)
                    }
                }
                if !model.tags.isEmpty {
                    Section("Tags") {
                        ForEach(model.tags, id: \.id) { tag in
                            Toggle(tag.label, isOn: Binding(
                                get: { tags.contains(tag.id) },
                                set: { on in if on { tags.insert(tag.id) } else { tags.remove(tag.id) } }
                            ))
                        }
                    }
                }
            }
            .navigationTitle("Edit \(artist.name ?? "")")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let saved = await model.save(changes)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving || changes.isEmpty)
                }
            }
        }
    }
}

/// One album: its tracks by disc and which are on disk, in what quality and
/// size, Monitor, Search, interactive search, deleting files, and history.
/// Its quality profile is the artist's, so there is no picker here.
public struct AlbumDetailView: View {
    @State private var model: AlbumDetailModel
    @State private var searching = false
    @Environment(\.confirmCenter) private var confirmCenter
    let baseURL: URL
    let api: any LibraryAPI & MusicLibraryAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void

    public init(id: Int, api: any LibraryAPI & MusicLibraryAPI & ExtrasAPI, baseURL: URL,
                onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        self.api = api
        self.onSessionLost = onSessionLost
        _model = State(initialValue: AlbumDetailModel(id: id, api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.album {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(album):
                BackdropSection(path: album.poster, baseURL: baseURL, blurred: true)
                Section {
                    DetailHero(poster: album.poster, baseURL: baseURL, overview: album.overview, links: model.links,
                               ratings: album.ratings ?? [], square: true) {
                        StateBadge(state: album.state)
                        // Lidarr's own word for it: Album, EP, Single…
                        if let type = album.album_type { Text(type) }
                        ForEach(album.secondary_types ?? [], id: \.self) { Text("· \($0)") }
                        // a release date, so with its year (Format.day is for dates near today)
                        if let raw = album.release_date, album.year != nil, let date = Format.parseDate(raw) {
                            Text("· \(date.formatted(.dateTime.day().month(.abbreviated).year()))")
                        }
                    }
                    if let artist = album.artist, !artist.isEmpty {
                        if let artistID = album.artist_id {
                            NavigationLink(value: MediaRef.artist(artistID)) {
                                Text(artist).foregroundStyle(Color.accent)
                            }
                            .accessibilityIdentifier("album-artist")
                        } else {
                            Text(artist)
                        }
                    }
                }
                actions(album)
                tracks(album)
                if let genres = album.genres, !genres.isEmpty {
                    Section("Genres") { GenreChips(genres: genres) }
                }
                DetailHistorySection(history: album.history)
            }
        }
        .dashboardListStyle()
        .navigationTitle(title)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $searching) {
            ReleasesSheet(target: .album(model.id), title: model.fullTitle, api: api, onSessionLost: onSessionLost) { searching = false }
        }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("album-detail")
    }

    var title: String {
        guard let album = model.album.value else { return "…" }
        return [album.title, album.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    func actions(_ album: AlbumDetail) -> some View {
        Section {
            let monitored = album.monitored ?? false
            Button(monitored ? "Unmonitor" : "Monitor") {
                ask(confirmCenter, monitored ? String(localized: "Unmonitor") : String(localized: "Monitor"), subject: album.title) {
                    await model.setMonitored(!monitored)
                }
            }
            Button("Search now") {
                ask(confirmCenter, String(localized: "Search now"), subject: album.title) { await model.search() }
            }
            Button("Interactive search") { searching = true }
                .accessibilityIdentifier("album-releases")
            if (album.track_file_count ?? 0) > 0 {
                Button("Delete the album's files", role: .destructive) {
                    ask(confirmCenter, String(localized: "Delete the album's files"), subject: album.title, destructive: true) {
                        await model.deleteFiles()
                    }
                }
            }
        } footer: {
            if let notice = model.notice { Text(notice) }
        }
        .disabled(model.busy)
    }

    /// The tracks under one heading, or per disc or side when there is
    /// more than one; the release, running time and size close the list.
    @ViewBuilder func tracks(_ album: AlbumDetail) -> some View {
        let discs = model.discs
        ForEach(discs, id: \.number) { disc in
            Section {
                ForEach(disc.tracks, id: \.id) { track in
                    AlbumTrackRow(track: track, albumMonitored: album.monitored ?? false, busy: model.busy) {
                        ask(confirmCenter, String(localized: "Delete file"), subject: track.title, destructive: true) {
                            await model.deleteFile(of: track)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    if disc.number == discs.first?.number {
                        Text("Tracks · \(album.track_file_count ?? 0) of \(album.track_count ?? 0) on disk")
                    }
                    if discs.count > 1 {
                        Text(disc.label.isEmpty ? String(localized: "Disc \(disc.number)")
                                                : String(localized: "Disc \(disc.number) · \(disc.label)"))
                    }
                }
            } footer: {
                if disc.number == discs.last?.number {
                    let summary = [album.release, MusicLayout.duration(album.duration),
                                   (album.size_on_disk ?? 0) > 0 ? Format.bytes(album.size_on_disk) : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !summary.isEmpty { Text(summary) }
                }
            }
        }
    }
}

/// One track: its number, title, whether its file is on disk, and that
/// file's quality and size; the file can be deleted from here.
struct AlbumTrackRow: View {
    let track: AlbumTrack
    let albumMonitored: Bool
    let busy: Bool
    let deleteFile: () -> Void

    var state: String { track.has_file == true ? "downloaded" : (albumMonitored ? "wanted" : "unmonitored") }

    var details: String {
        var parts = [MusicLayout.duration(track.duration)]
        if track.has_file == true {
            if let quality = track.quality { parts.append(quality) }
            if let size = track.size, size > 0 { parts.append(Format.bytes(size)) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: track.number ?? String(track.absolute ?? 0))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title ?? "").font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    StateBadge(state: state)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if track.file_id != nil {
                Button(role: .destructive, action: deleteFile) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.danger)
                .disabled(busy)
                .accessibilityLabel(Text("Delete the file of \(track.title ?? "")"))
            }
        }
    }
}
