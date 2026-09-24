import ArrdeckData
import SwiftUI

/// The API a library tab needs, the per-kind views included.
public typealias LibraryPageAPI = ManageAPI & LibraryAPI & ExtrasAPI & DiscoverAPI & WantedAPI & BookShelfAPI

/// A title's detail page, from any list that can open one. Given the list's
/// order it also steps to the next or previous title — toolbar arrows or a
/// horizontal swipe — in place, so Back still returns to the list.
struct MediaDestination: View {
    let api: any LibraryPageAPI
    let baseURL: URL
    let hasPlex: Bool
    let sequence: [MediaRef]
    let onSessionLost: @MainActor () -> Void
    @State private var current: MediaRef

    init(ref: MediaRef, api: any LibraryPageAPI, baseURL: URL, hasPlex: Bool, sequence: [MediaRef] = [],
         onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.sequence = sequence
        self.onSessionLost = onSessionLost
        _current = State(initialValue: ref)
    }

    var neighbours: (previous: MediaRef?, next: MediaRef?) { TitleSequence.neighbours(of: current, in: sequence) }

    var body: some View {
        detail
            .id(current)
            .toolbar {
                if neighbours.previous != nil || neighbours.next != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { step(neighbours.previous) } label: { Image(systemName: "chevron.up") }
                            .disabled(neighbours.previous == nil)
                            .accessibilityLabel("Previous title")
                        Button { step(neighbours.next) } label: { Image(systemName: "chevron.down") }
                            .disabled(neighbours.next == nil)
                            .accessibilityLabel("Next title")
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 40).onEnded { value in
                    // away from the left edge, which belongs to the back swipe
                    guard value.startLocation.x > 40,
                          abs(value.translation.width) > 90,
                          abs(value.translation.height) < abs(value.translation.width) * 0.6 else { return }
                    step(value.translation.width < 0 ? neighbours.next : neighbours.previous)
                }
            )
            .sensoryFeedback(.selection, trigger: current)
    }

    func step(_ ref: MediaRef?) {
        if let ref { current = ref }
    }

    @ViewBuilder var detail: some View {
        switch current {
        case let .movie(id):
            MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
        case let .series(id):
            SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
        case let .book(id):
            BookDetailView(id: id, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
        }
    }
}

/// A thin have/total bar: a season, a series of books, a collection.
struct Completion: View {
    let have: Int
    let total: Int

    var body: some View {
        if total > 0 {
            ProgressView(value: Double(min(have, total)), total: Double(total))
                .tint(have >= total ? Color.success : Color.accent)
        }
    }
}

/// Shows in airing order, with how much of the season is on disk; shows with
/// nothing on the calendar fold away below.
struct UpNextList: View {
    let rows: [LibraryRow]
    let baseURL: URL
    @State private var showIdle = false

    var body: some View {
        let split = LibrarySorting.upNext(rows)
        VStack(alignment: .leading, spacing: 14) {
            if split.airing.isEmpty {
                EmptyNote("Nothing on the calendar for the next four months.")
            } else {
                card(split.airing)
            }
            if !split.idle.isEmpty {
                DisclosureGroup(isExpanded: $showIdle) {
                    card(split.idle).padding(.top, 8)
                } label: {
                    Text("Not airing (\(split.idle.count))").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    func card(_ rows: [LibraryRow]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                NavigationLink(value: row.ref) { UpNextRow(row: row, baseURL: baseURL) }
                    .buttonStyle(.plain)
                if row.id != rows.last?.id { Divider().padding(.leading, 12) }
            }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct UpNextRow: View {
    let row: LibraryRow
    let baseURL: URL
    // an episode that has not aired cannot have been watched, so any spoiler
    // setting hides its title here
    @AppStorage(DisplayKeys.spoilers) private var spoilers: Spoilers = .off

    var code: String? {
        guard let next = row.nextEpisode else { return nil }
        return String(format: "S%02dE%02d", next.season, next.episode)
    }

    var body: some View {
        HStack(spacing: 12) {
            Poster(path: row.poster, baseURL: baseURL, width: 44, cornerRadius: 6, title: row.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let code {
                    HStack(spacing: 6) {
                        (Text(verbatim: code).bold() + Text(verbatim: spoilers == .off ? (row.nextEpisode?.title.map { " · \($0)" } ?? "") : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let finale = FinaleLabel.text(row.nextEpisode?.finale_type) {
                            Text(finale).font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(Color.accent)
                        }
                    }
                } else {
                    Text(row.status == "ended" ? "Ended" : "Nothing scheduled")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let season = row.currentSeason, let total = season.total, total > 0 {
                    HStack(spacing: 6) {
                        Completion(have: season.have ?? 0, total: total)
                        Text(verbatim: "S\(season.number) · \(season.have ?? 0)/\(total)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let air = row.nextEpisode?.air_date {
                Text(Format.when(air))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// The Books tab as a bookshelf: series in reading order with gaps for the
/// missing volumes, or every author's books side by side.
struct ShelfView: View {
    enum Grouping: String, CaseIterable { case series, authors }

    let rows: [LibraryRow]
    let query: String
    let api: any BookShelfAPI
    let baseURL: URL
    @AppStorage("shelf.grouping") private var grouping: Grouping = .series
    @State private var shelf: Loadable<[ShelfSeries]> = .loading

    func matches(_ values: String?...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || values.contains { ($0 ?? "").lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Group by", selection: $grouping) {
                Text("Series").tag(Grouping.series)
                Text("Authors").tag(Grouping.authors)
            }
            .pickerStyle(.segmented)
            switch grouping {
            case .series: seriesShelves
            case .authors: authorShelves
            }
        }
        .task(id: grouping) {
            guard grouping == .series, shelf.value == nil else { return }
            do { shelf = .loaded(try await api.bookShelf()) } catch { shelf = .failed(error.localizedDescription) }
        }
    }

    @ViewBuilder var seriesShelves: some View {
        switch shelf {
        case .loading: LoadingRow()
        case let .failed(reason): ErrorNote(reason)
        case let .loaded(all):
            let shown = all.filter { s in matches(s.title, s.author) || (s.books ?? []).contains { matches($0.title) } }
            if shown.isEmpty { EmptyNote("None of your books belong to a series Readarr knows.") }
            ForEach(shown, id: \.id) { series in
                Shelf(title: series.title ?? "", subtitle: series.author, have: series.have, total: series.total) {
                    ForEach(series.books ?? [], id: \.book_id) { book in
                        NavigationLink(value: MediaRef.book(book.book_id)) {
                            ShelfTile(title: book.title ?? "", poster: book.poster, position: book.position,
                                      owned: book.has_file == true || book.monitored == true,
                                      onDisk: book.has_file == true, baseURL: baseURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder var authorShelves: some View {
        let byAuthor = Dictionary(grouping: rows.filter { matches($0.title, $0.author, $0.seriesTitle) }) { $0.author ?? "—" }
        if byAuthor.isEmpty { EmptyNote("No matches") }
        ForEach(byAuthor.keys.sorted(), id: \.self) { author in
            let books = (byAuthor[author] ?? []).sorted { ($0.year ?? 0) < ($1.year ?? 0) }
            Shelf(title: author, subtitle: String(localized: "\(books.count) books"), have: nil, total: nil) {
                ForEach(books) { book in
                    NavigationLink(value: book.ref) {
                        ShelfTile(title: book.title, poster: book.poster, position: nil, owned: true,
                                  onDisk: book.status == "downloaded", baseURL: baseURL)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct Shelf<Content: View>: View {
    let title: String
    let subtitle: String?
    let have: Int?
    let total: Int?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let have, let total { Text(verbatim: "\(have) / \(total)").font(.caption).foregroundStyle(.secondary) }
            }
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            if let have, let total { Completion(have: have, total: total) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content() }
            }
            .padding(.horizontal, -16)
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
    }
}

private struct ShelfTile: View {
    let title: String
    let poster: String?
    let position: String?
    let owned: Bool
    let onDisk: Bool
    let baseURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if owned {
                Poster(path: poster, baseURL: baseURL, width: 90, cornerRadius: 10, title: title)
                    .opacity(onDisk ? 1 : 0.6)
                    .overlay(alignment: .topLeading) {
                        if let position {
                            Text(verbatim: "#\(position)").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
            } else {
                // a gap in the series: dashed, with the number it would sit at
                VStack(spacing: 4) {
                    if let position { Text(verbatim: "#\(position)").font(.headline) }
                    Text(title).font(.caption2).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(width: 90, height: 135)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(.tertiary))
            }
            Text(title).font(.caption2).lineLimit(1).frame(width: 90, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(owned ? Text(title) : Text("Missing: \(title)"))
    }
}

/// Radarr's collections as the Movies tab's view, each with how complete it is.
struct CollectionsLibraryList: View {
    let api: any DiscoverAPI & LibraryAPI
    let baseURL: URL
    let query: String
    @State private var collections: Loadable<[ArrdeckData.Collection]> = .loading
    @State private var open: ArrdeckData.Collection?

    var body: some View {
        Group {
            switch collections {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(all):
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = all.filter { needle.isEmpty || ($0.title ?? "").lowercased().contains(needle) }
                if shown.isEmpty { EmptyNote("No matches") }
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.id) { item in
                        Button { open = item } label: { row(item) }.buttonStyle(.plain)
                        if item.id != shown.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await load() }
        .sheet(item: $open) { item in
            CollectionSheet(collection: item, api: api, baseURL: baseURL) { open = nil; Task { await load() } }
        }
    }

    func row(_ item: ArrdeckData.Collection) -> some View {
        let total = item.movie_count ?? 0
        let have = total - (item.missing_count ?? 0)
        return HStack(spacing: 12) {
            Poster(path: item.poster, baseURL: baseURL, width: 40, cornerRadius: 6, title: item.title ?? "")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(have) of \(total) movies").font(.caption).foregroundStyle(.secondary)
                Completion(have: have, total: total)
            }
            Spacer(minLength: 0)
            if item.monitored == true { Image(systemName: "bookmark.fill").foregroundStyle(Color.accent) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    func load() async {
        do { collections = .loaded(try await api.collections()) } catch { collections = .failed(error.localizedDescription) }
    }
}

/// "Season finale", "Series finale", "Midseason finale" for Sonarr's finaleType.
enum FinaleLabel {
    static func text(_ type: String?) -> String? {
        switch type {
        case "season": String(localized: "Season finale")
        case "series": String(localized: "Series finale")
        case "midseason": String(localized: "Midseason finale")
        default: nil
        }
    }
}
