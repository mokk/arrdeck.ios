import ArrdeckData
import SwiftUI

/// An author as Readarr keeps them: monitoring, what to do with new books,
/// and every book including the unmonitored ones the Books tab hides — this
/// is where one of those gets monitored again.
public struct AuthorDetailView: View {
    @State private var model: AuthorDetailModel
    let baseURL: URL
    let api: any LibraryAPI

    public init(id: Int, api: any LibraryAPI, baseURL: URL, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.baseURL = baseURL
        _model = State(initialValue: AuthorDetailModel(id: id, api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.author {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(author):
                Section {
                    DetailHero(poster: author.poster, baseURL: baseURL, overview: author.overview, links: []) {
                        Text("\(author.available_count ?? 0) of \(author.book_count ?? 0) books on disk")
                        if let size = author.size_on_disk, size > 0 { Text("· \(Format.bytes(size))") }
                    }
                }
                Section {
                    Toggle("Author monitored", isOn: Binding(
                        get: { author.monitored ?? false },
                        set: { value in Task { await model.setMonitored(value) } }
                    ))
                    Picker("New books", selection: Binding(
                        get: { author.monitor_new_items ?? "none" },
                        set: { value in Task { await model.setMonitorNewItems(value) } }
                    )) {
                        Text("Monitor all").tag("all")
                        Text("Monitor new").tag("new")
                        Text("Do not monitor").tag("none")
                    }
                }
                .disabled(model.busy)
                Section("Books (\(author.books?.count ?? 0))") {
                    ForEach(author.books ?? [], id: \.id) { book in
                        AuthorBookRow(book: book, model: model)
                    }
                }
                ForEach(author.series ?? [], id: \.id) { series in
                    Section("Series: \(series.title ?? "")") {
                        ForEach(series.books ?? [], id: \.book_id) { entry in
                            SeriesBookRow(entry: entry, current: false)
                        }
                    }
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle(model.author.value?.name ?? "…")
        .task { await model.load() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("author-detail")
    }
}

struct AuthorBookRow: View {
    let book: LibraryBook
    let model: AuthorDetailModel

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: MediaRef.book(book.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(book.title ?? "").font(.subheadline).lineLimit(1)
                        if let year = book.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 6) {
                        StateBadge(state: book.has_file == true ? "downloaded" : (book.monitored == true ? "wanted" : "unmonitored"))
                        if let series = book.series_title { Text(series).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            Spacer(minLength: 0)
            Button(book.monitored == true ? "Unmonitor" : "Monitor") {
                Task { await model.setBookMonitored(book, !(book.monitored ?? false)) }
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(model.busy)
        }
    }
}
