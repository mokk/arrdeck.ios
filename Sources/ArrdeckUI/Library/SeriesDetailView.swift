import ArrdeckData
import SwiftUI

public struct SeriesDetailView: View {
    @State private var model: SeriesDetailModel
    @State private var searching: ReleaseSearch?
    @Environment(\.dismiss) private var dismiss
    let baseURL: URL
    let api: any LibraryAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void

    struct ReleaseSearch: Identifiable {
        let target: ReleaseTarget
        let title: String
        var id: ReleaseTarget { target }
    }

    public init(id: Int, api: any LibraryAPI & ExtrasAPI, baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        self.baseURL = baseURL
        self.api = api
        self.onSessionLost = onSessionLost
        _model = State(initialValue: SeriesDetailModel(id: id, api: api, hasPlex: hasPlex, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            switch model.series {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(series):
                Section {
                    DetailHero(poster: series.poster, baseURL: baseURL, overview: series.overview, links: model.links) {
                        StateBadge(state: series.monitored == true ? "ok" : "unmonitored")
                        if let status = series.status { Text(status.capitalized) }
                        if let network = series.network { Text("· \(network)") }
                        if let runtime = series.runtime, runtime > 0 { Text("· \(runtime) min/ep") }
                        if let certification = series.certification { Text("· \(certification)") }
                    }
                }
                RenameCard(ref: .series(series.id), api: api, onSessionLost: onSessionLost)
                DetailActions(model: model, monitored: series.monitored ?? false) { EmptyView() }
                // A series has no single file, so the movie page's file card
                // becomes the ratio of episodes on disk. total_episode_count
                // includes unaired ones, shown separately rather than as the
                // denominator.
                Section("On disk") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(series.episode_file_count ?? 0)/\(series.episode_count ?? 0)")
                            .font(.subheadline.weight(.medium))
                        Text(onDiskDetails(series)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(series.seasons, id: \.number) { season in
                    SeasonSection(season: season, model: model) { target, label in
                        searching = ReleaseSearch(target: target, title: "\(series.title ?? "") — \(label)")
                    }
                }
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
        .sheet(item: $searching) { search in
            ReleasesSheet(target: search.target, title: search.title, api: api, onSessionLost: onSessionLost) { searching = nil }
        }
        .accessibilityIdentifier("series-detail")
    }

    func onDiskDetails(_ series: SeriesDetail) -> String {
        var parts = [Format.bytes(series.size_on_disk)]
        if let seasons = series.season_count, seasons > 0 {
            parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons")
        }
        if let total = series.total_episode_count, total > (series.episode_count ?? 0) {
            parts.append("\(total) incl. unaired")
        }
        return parts.joined(separator: " · ")
    }

    var title: String {
        guard let series = model.series.value else { return "…" }
        return [series.title, series.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }

    var actionFailed: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

struct SeasonSection: View {
    let season: Season
    let model: SeriesDetailModel
    let search: (ReleaseTarget, String) -> Void

    var label: String { season.number == 0 ? "Specials" : "Season \(season.number)" }
    var open: Bool { model.expanded.contains(season.number) }

    var body: some View {
        Section {
            Button {
                Task { await model.toggle(season: season.number) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                            Text(label).font(.subheadline.weight(.semibold))
                            if !season.monitored { StateBadge(state: "unmonitored") }
                        }
                        Text("\(season.episode_file_count ?? 0)/\(season.episode_count ?? 0) · \(Format.bytes(season.size_on_disk))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(season.monitored ? "Unmonitor" : "Monitor") {
                        Task { await model.setSeasonMonitored(season, !season.monitored) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button("Search") { Task { await model.searchSeason(season) } }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button {
                        search(.season(series: model.ref.id, season: season.number), label)
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Interactive search")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.busy)

            if open {
                switch model.episodes[season.number] ?? .loading {
                case .loading:
                    LoadingRow()
                case let .failed(reason):
                    ErrorNote(reason)
                case let .loaded(episodes):
                    ForEach(episodes, id: \.id) { episode in
                        EpisodeRow(episode: episode, model: model) {
                            search(.episode(series: model.ref.id, episode: episode.id),
                                   "\(String(format: "E%02d", episode.episode)) \(episode.title ?? "")")
                        }
                    }
                }
            }
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let model: SeriesDetailModel
    let search: () -> Void
    @State private var confirmingDelete = false

    var fileDetails: String? {
        guard episode.has_file == true else { return nil }
        let parts = [episode.quality, episode.size.map { Format.bytes($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(String(format: "E%02d", episode.episode)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(episode.title ?? "").font(.subheadline).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if episode.has_file == true {
                        StateBadge(state: "downloaded")
                    } else {
                        StateBadge(state: episode.monitored == true ? "wanted" : "paused")
                    }
                    Text(Format.day(episode.air_date)).font(.caption).foregroundStyle(.secondary)
                    if let fileDetails { Text("· \(fileDetails)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            if episode.has_file == true, episode.file_id != nil {
                if confirmingDelete {
                    Button("Delete file?", role: .destructive) {
                        confirmingDelete = false
                        Task { await model.deleteFile(of: episode) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Delete file", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            Button(episode.monitored == true ? "Unmonitor" : "Monitor") {
                Task { await model.setEpisodeMonitored(episode, !(episode.monitored ?? false)) }
            }
            .buttonStyle(.borderless).controlSize(.small)
            if episode.has_file != true {
                Button("Search") { Task { await model.searchEpisode(episode) } }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            Button(action: search) { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("Interactive search")
        }
        if episode.has_file == true, let subtitles = model.subtitles[episode.id] {
            SubtitleTracksView(subtitles: subtitles, busy: model.busy) { code in
                Task { await model.getSubtitle(episode: episode, language: code) }
            }
        }
        }
        .disabled(model.busy)
    }
}
