import ArrdeckData
import SwiftUI

public struct MovieDetailView: View {
    @State private var model: MovieDetailModel
    @Environment(\.dismiss) private var dismiss
    let baseURL: URL

    public init(id: Int, api: any LibraryAPI, baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        _model = State(initialValue: MovieDetailModel(id: id, api: api, hasPlex: hasPlex, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.movie {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(movie):
                Section {
                    DetailHero(poster: movie.poster, baseURL: baseURL, overview: movie.overview, links: model.links) {
                        StateBadge(state: movie.has_file == true ? "downloaded" : (movie.monitored == true ? "wanted" : "unmonitored"))
                        if let status = movie.status { Text(status.capitalized) }
                        if let runtime = movie.runtime, runtime > 0 { Text("· \(runtime) min") }
                    }
                }
                DetailActions(model: model, monitored: movie.monitored ?? false)
                Section("File") {
                    if let file = movie.file {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(file.quality ?? "").font(.subheadline.weight(.medium))
                                if let resolution = file.resolution {
                                    Text("· \(resolution)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Text([Format.bytes(file.size), file.release_group].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        EmptyNote("No file")
                    }
                }
                CreditsSection(credits: model.credits, baseURL: baseURL)
                DetailHistorySection(history: movie.history)
            }
        }
        .dashboardListStyle()
        .navigationTitle(title)
        .toolbar { WatchedDot(watched: model.watched) }
        .task { await model.load() }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("movie-detail")
    }

    var title: String {
        guard let movie = model.movie.value else { return "…" }
        return [movie.title, movie.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    var actionFailed: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}
