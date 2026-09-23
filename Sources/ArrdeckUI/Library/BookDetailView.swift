import ArrdeckData
import SwiftUI

/// A book: cover, author, synopsis, the ratings Readarr carries, monitor /
/// profile / search / delete, editions and history. Quality is the author's
/// setting in Readarr, so the profile picker changes every book of theirs.
public struct BookDetailView: View {
    @State private var model: BookDetailModel
    @State private var searching = false
    @State private var downloader = FileDownloadModel()
    @State private var sharing: URL?
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
                BackdropSection(path: book.poster, baseURL: baseURL, blurred: true)
                Section {
                    DetailHero(poster: book.poster, baseURL: baseURL, overview: book.overview, links: model.links) {
                        StateBadge(state: book.has_file == true ? "downloaded" : (book.monitored == true ? "wanted" : "unmonitored"))
                        if let author = book.author {
                            if let authorID = book.author_id {
                                NavigationLink {
                                    AuthorDetailView(id: authorID, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
                                } label: { Text(author).foregroundStyle(Color.accent) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("book-author")
                            } else {
                                Text(author)
                            }
                        }
                        if let pages = book.page_count, pages > 0 { Text("· \(pages) pages") }
                        if let rating = book.rating { Text("· ★ \(rating.formatted(.number.precision(.fractionLength(1))))") }
                    }
                    if let series = book.series_title { Text(series).font(.caption).foregroundStyle(.secondary) }
                }
                DetailActions(model: model, monitored: book.monitored ?? false) {
                    Button("Interactive search") { searching = true }
                }
                if let reading = api as? any ReadingAPI {
                    ReadingSection(bookID: book.id, api: reading)
                }
                Section("File") {
                    if let files = book.files, !files.isEmpty {
                        ForEach(files, id: \.id) { file in
                            BookFileRow(
                                file: file,
                                fallbackName: book.title ?? "",
                                downloadable: book.downloadable == true,
                                downloader: downloader,
                                url: fileURL(book: book.id, file: file.id)
                            )
                        }
                    } else if book.has_file == true {
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
                ForEach(book.series ?? [], id: \.id) { series in
                    Section("Series: \(series.title ?? "")") {
                        ForEach(series.books ?? [], id: \.book_id) { entry in
                            SeriesBookRow(entry: entry, current: entry.book_id == book.id)
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
        .onChange(of: downloader.state) { _, state in
            if case let .done(url) = state { sharing = url }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(url: sharing) }
        }
        #endif
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

    /// arrdeck proxies the file from our Readarr fork; the session cookie in
    /// the shared jar authenticates the request like every other call.
    func fileURL(book: Int, file: Int) -> URL {
        baseURL.appending(path: "api/v1/library/books/\(book)/files/\(file)")
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


/// One stored file: format and size, and — only when the connected Readarr is
/// our fork — a Download that ends in the share sheet, so the book can go to
/// Apple Books or Files. Upstream Readarr has no endpoint to serve files.
struct BookFileRow: View {
    let file: BookFile
    let fallbackName: String
    let downloadable: Bool
    let downloader: FileDownloadModel
    let url: URL

    var details: String {
        [file.format, Format.bytes(file.size)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name ?? fallbackName).font(.subheadline).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloadable {
                switch downloader.state {
                case .downloading:
                    ProgressView()
                case let .done(saved):
                    ShareLink(item: saved) { Label("Open in…", systemImage: "square.and.arrow.up").labelStyle(.titleOnly) }
                        .font(.subheadline.weight(.semibold))
                case .idle, .failed:
                    Button {
                        Task { await downloader.download(url, suggestedName: file.name ?? fallbackName) }
                    } label: { Label("Download", systemImage: "arrow.down.circle").labelStyle(.titleOnly) }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("book-download")
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if case let .failed(reason) = downloader.state {
                Text(reason).font(.caption2).foregroundStyle(Color.danger).offset(y: 14)
            }
        }
    }
}

#if os(iOS)
import UIKit

/// The system share sheet: "Copy to Books", "Save to Files" and any reader app.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

/// One volume of a book series: its position, the title, and whether you
/// have it. Other volumes open their own page.
struct SeriesBookRow: View {
    let entry: SeriesBook
    let current: Bool

    var body: some View {
        let content = HStack(spacing: 10) {
            Text(verbatim: entry.position.map { "#\($0)" } ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Text(entry.title ?? "").font(current ? .subheadline.weight(.semibold) : .subheadline).lineLimit(1)
            Spacer()
            StateBadge(state: entry.has_file == true ? "downloaded" : (entry.monitored == true ? "wanted" : "unmonitored"))
        }
        if current {
            content
        } else {
            NavigationLink(value: MediaRef.book(entry.book_id)) { content }
        }
    }
}
