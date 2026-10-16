import ArrdeckData
import SwiftUI

public struct MovieDetailView: View {
    @State private var model: MovieDetailModel
    @State private var searching = false
    @Environment(\.dismiss) private var dismiss
    let api: any LibraryAPI & ExtrasAPI

    public init(id: Int, api: any LibraryAPI & ExtrasAPI, hasPlex: Bool) {
        self.api = api
        _model = State(initialValue: MovieDetailModel(id: id, api: api, hasPlex: hasPlex))
    }

    public var body: some View {
        List {
            switch model.movie {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(movie):
                BackdropSection(path: movie.fanart)
                Section {
                    DetailHero(poster: movie.poster, overview: movie.overview, links: model.links,
                               ratings: movie.ratings ?? []) {
                        StateBadge(state: movie.has_file == true ? "downloaded" : (movie.monitored == true ? "wanted" : "unmonitored"))
                        if let status = movie.status { Text(status.capitalized) }
                        if let runtime = movie.runtime, runtime > 0 { Text("· \(runtime) min") }
                    }
                }
                RequestBannerSection(api: api, movieTMDB: movie.tmdb_id, showTVDB: nil)
                RenameCard(ref: .movie(movie.id), api: api)
                DetailActions(model: model, monitored: movie.monitored ?? false) {
                    Button("Interactive search") { searching = true }
                }
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
                if let subtitles = model.subtitles {
                    Section("Subtitles") {
                        SubtitleTracksView(subtitles: subtitles, busy: model.busy) { code in
                            Task { await model.getSubtitle(language: code) }
                        }
                    }
                }
                CreditsSection(credits: model.credits)
                DetailHistorySection(history: movie.history)
            }
        }
        .dashboardListStyle()
        .chromePage(title: title) { WatchedDot(watched: model.watched) }
        .navigationTitle(title)
        // opened from iOS search the page sits in a sheet, which keeps its bar
        .toolbar { WatchedDot(watched: model.watched) }
        .navigationDestination(for: PersonRef.self) { ref in
            if let people = api as? any PeopleAPI {
                PersonView(ref: ref, api: people, adder: api as? any DiscoverAPI & LibraryAPI)
            }
        }
        .task { await model.load() }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: $searching) {
            ReleasesSheet(target: .movie(model.ref.id), title: title, api: api) { searching = false }
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
