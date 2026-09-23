import ArrdeckData
import SwiftUI

/// Poster, synopsis and the metadata line. `badges` differs per kind — a
/// film has a runtime, a series has a network and an episode ratio — so the
/// caller supplies it rather than the view guessing from optional fields.
struct DetailHero<Badges: View>: View {
    let poster: String?
    let baseURL: URL
    let overview: String?
    let links: [ExternalLink]
    @ViewBuilder let badges: () -> Badges

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                if poster != nil {
                    Poster(path: poster, baseURL: baseURL, width: 100, cornerRadius: 12)
                }
                if let overview, !overview.isEmpty {
                    Text(overview).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            // Full width under the poster: beside it the line wrapped mid-word.
            HStack(spacing: 6) { badges() }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !links.isEmpty {
                HStack(spacing: 6) {
                    ForEach(links, id: \.self) { link in
                        Link(destination: link.url) {
                            Text("\(link.label) ↗")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Monitor, search, delete — delete behind a confirmation because both
/// variants are irreversible and one of them removes files.
struct DetailActions<Extra: View>: View {
    let model: DetailModelBase
    let monitored: Bool
    /// Interactive search on the movie page; the series page offers it per
    /// season instead, because Sonarr's release lookup needs a season or an
    /// episode.
    @ViewBuilder let extra: () -> Extra
    @State private var confirmingDelete = false
    @Environment(\.confirmCenter) private var confirmCenter

    var body: some View {
        Section {
            if !model.qualityProfiles.isEmpty {
                ProfilePicker(model: model, selected: selectedProfile)
            }
            Button(monitored ? "Unmonitor" : "Monitor") {
                ask(confirmCenter, monitored ? String(localized: "Unmonitor") : String(localized: "Monitor")) {
                    await model.setMonitored(!monitored)
                }
            }
            Button("Search now") { ask(confirmCenter, String(localized: "Search now")) { await model.search() } }
            extra()
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
        .disabled(model.busy)
        .confirmationDialog("Delete", isPresented: $confirmingDelete, titleVisibility: .hidden) {
            Button("Delete from library and disk", role: .destructive) {
                Task { await model.delete(deleteFiles: true) }
            }
            Button("Remove from library only", role: .destructive) {
                Task { await model.delete(deleteFiles: false) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    var selectedProfile: Int? {
        switch model {
        case let movie as MovieDetailModel: movie.movie.value?.quality_profile_id
        case let series as SeriesDetailModel: series.series.value?.quality_profile_id
        case let book as BookDetailModel: book.book.value?.quality_profile_id
        default: nil
        }
    }
}

struct ProfilePicker: View {
    let model: DetailModelBase
    let selected: Int?

    var body: some View {
        Picker("Quality profile", selection: Binding(
            get: { selected ?? -1 },
            set: { id in if id != selected { Task { await model.setQualityProfile(id) } } }
        )) {
            if selected == nil { Text("—").tag(-1) }
            ForEach(model.qualityProfiles, id: \.id) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
    }
}

struct DetailHistorySection: View {
    let history: [HistoryEvent]?

    var body: some View {
        if let history, !history.isEmpty {
            Section("Recent history") {
                ForEach(Array(history.enumerated()), id: \.offset) { _, event in
                    HStack {
                        StateBadge(state: event._type)
                        Spacer()
                        Text(Format.dayTime(event.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Cast and crew. Nothing at all when the arr has no credits for a title,
/// rather than an empty card.
struct CreditsSection: View {
    let credits: Credits?
    let baseURL: URL

    var body: some View {
        let cast = credits?.cast ?? []
        let crew = credits?.crew ?? []
        if !cast.isEmpty || !crew.isEmpty {
            Section("Cast & crew") {
                if !cast.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                                if let id = person.tmdb_id {
                                    NavigationLink(value: PersonRef(id)) { PersonChip(person: person, baseURL: baseURL) }
                                        .buttonStyle(.plain)
                                } else {
                                    PersonChip(person: person, baseURL: baseURL)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .listRowInsets(EdgeInsets())
                }
                ForEach(Array(crew.enumerated()), id: \.offset) { _, person in
                    if let id = person.tmdb_id {
                        NavigationLink(value: PersonRef(id)) { crewLine(person) }
                    } else {
                        crewLine(person)
                    }
                }
            }
        }
    }
}

private func crewLine(_ person: CreditPerson) -> some View {
    HStack {
        Text(person.name).font(.subheadline)
        Spacer()
        Text(person.role ?? "").font(.caption).foregroundStyle(.secondary)
    }
}

struct PersonChip: View {
    let person: CreditPerson
    let baseURL: URL

    /// A quarter of a cast list has no headshot on TMDB, and a grey box beside
    /// a photo reads as a broken image rather than a missing one.
    var initials: String {
        let parts = person.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }

    var body: some View {
        VStack(spacing: 4) {
            if let image = person.image, let url = URL(string: image, relativeTo: baseURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(.quaternary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(Circle())
            } else {
                Circle().fill(.quaternary).frame(width: 56, height: 56)
                    .overlay(Text(initials).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary))
            }
            Text(person.name).font(.caption2.weight(.semibold)).lineLimit(1)
            Text(person.role ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 72)
    }
}

struct WatchedDot: View {
    let watched: Watched?

    var body: some View {
        if let watched {
            Circle()
                .fill(watched.watched ? Color.success : (watched.progress > 0 ? Color.warning : Color.secondary.opacity(0.3)))
                .frame(width: 8, height: 8)
                .accessibilityLabel(watched.watched ? "Watched" : "Unwatched")
        }
    }
}
