import ArrdeckData
import SwiftUI

/// A book: cover, author, synopsis, the ratings Readarr carries, monitor /
/// profile / search / delete, editions and history. Quality is the author's
/// setting in Readarr, so the profile picker changes every book of theirs.
public struct BookDetailView: View {
    @State private var model: BookDetailModel
    @State private var searching = false
    @Environment(\.dismiss) private var dismiss
    let baseURL: URL
    let api: any LibraryAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void

    public init(id: Int, api: any LibraryAPI & ExtrasAPI, baseURL: URL, onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        self.api = api
        self.onSessionLost = onSessionLost
        _model = State(initialValue: BookDetailModel(id: id, api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.book {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(book):
                Section {
                    DetailHero(poster: book.poster, baseURL: baseURL, overview: book.overview, links: model.links) {
                        StateBadge(state: book.has_file == true ? "downloaded" : (book.monitored == true ? "wanted" : "unmonitored"))
                        if let author = book.author { Text(author) }
                        if let pages = book.page_count, pages > 0 { Text("· \(pages) pages") }
                        if let rating = book.rating { Text("· ★ \(rating.formatted(.number.precision(.fractionLength(1))))") }
                    }
                    if let series = book.series_title { Text(series).font(.caption).foregroundStyle(.secondary) }
                }
                DetailActions(model: model, monitored: book.monitored ?? false) {
                    Button("Interactive search") { searching = true }
                }
                Section("File") {
                    if book.has_file == true {
                        Text(Format.bytes(book.size_on_disk)).font(.subheadline.weight(.medium))
                    } else {
                        EmptyNote("No file")
                    }
                }
                if let editions = book.editions, !editions.isEmpty {
                    Section("Editions") {
                        ForEach(Array(editions.enumerated()), id: \.offset) { _, edition in
                            EditionRow(edition: edition, fallbackTitle: book.title ?? "")
                        }
                    }
                }
                if let genres = book.genres, !genres.isEmpty {
                    Section("Genres") {
                        Text(genres.prefix(6).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DetailHistorySection(history: book.history)
            }
        }
        .dashboardListStyle()
        .navigationTitle(title)
        .task { await model.load() }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .sheet(isPresented: $searching) {
            ReleasesSheet(target: .book(model.ref.id), title: title, api: api, onSessionLost: onSessionLost) { searching = false }
        }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("book-detail")
    }

    var title: String {
        guard let book = model.book.value else { return "…" }
        return [book.title, book.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    var actionFailed: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

struct EditionRow: View {
    let edition: BookEdition
    let fallbackTitle: String

    var details: String {
        var parts: [String] = []
        if let format = edition.format { parts.append(format) }
        if let pages = edition.page_count { parts.append("\(pages) pages") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(edition.title ?? fallbackTitle).font(.subheadline).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if edition.monitored == true { StateBadge(state: "monitored") }
        }
    }
}
