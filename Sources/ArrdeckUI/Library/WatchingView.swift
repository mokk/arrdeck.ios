import ArrdeckData
import SwiftUI

/// Statistics → Watching: Plex's own play history — how much, who, what and
/// when. Hours are an estimate; Plex does not record how long a play lasted.
struct WatchingSections: View {
    let api: any WatchingAPI
    let baseURL: URL
    @AppStorage("watching.window") private var window: WatchWindow = .month
    @State private var stats: Loadable<Block<WatchStats>> = .loading

    var body: some View {
        Section {
            Picker("Period", selection: $window) {
                ForEach(WatchWindow.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .task(id: window) { await load() }
        switch stats {
        case .loading: Section { LoadingRow() }
        case let .failed(reason): Section { ErrorNote(reason) }
        case let .loaded(block):
            if let reason = block.offlineReason { Section { ErrorNote(reason) } }
            if let data = block.value {
                if (data.plays ?? 0) == 0 {
                    Section { EmptyNote("Nothing watched in this period.") }
                } else {
                    content(data)
                }
            }
        }
    }

    @ViewBuilder func content(_ data: WatchStats) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                Tile(label: String(localized: "Plays"), value: "\(data.plays ?? 0)")
                Tile(label: String(localized: "Hours"), value: "≈ \(Self.hours(data.hours ?? 0))")
                Tile(label: String(localized: "Movies"), value: "\(data.movies ?? 0)")
                Tile(label: String(localized: "Episodes"), value: "\(data.episodes ?? 0)")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        if let shows = data.top_shows, !shows.isEmpty {
            Section("Most watched shows") { TitleStrip(rows: shows, movies: false, baseURL: baseURL) }
        }
        if let movies = data.top_movies, !movies.isEmpty {
            Section("Most watched movies") { TitleStrip(rows: movies, movies: true, baseURL: baseURL) }
        }
        Section {
            Bars(label: String(localized: "By weekday"), values: data.by_weekday ?? [], names: Self.weekdays)
            Bars(label: String(localized: "By time of day"), values: data.by_hour ?? [],
                 names: (0..<24).map { String(format: "%02d:00", $0) })
        }
        if let users = data.users, users.count > 1 {
            Section("Who watched") {
                ForEach(users, id: \.name) { user in
                    HStack {
                        Text(verbatim: user.name).lineLimit(1)
                        Spacer()
                        Text("\(user.plays ?? 0) plays · ≈ \(Self.hours(user.hours ?? 0)) h")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section {
        } footer: {
            Text("From Plex's play history. Hours are an estimate: each play counts the movie's runtime or the show's usual episode length.")
        }
    }

    /// Monday first, as the server counts; 1 January 2024 was a Monday.
    static var weekdays: [String] {
        (0..<7).map { day in
            let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2024, month: 1, day: 1 + day)) ?? .now
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }

    func load() async {
        do {
            stats = .loaded(try await api.watchStats(days: window.rawValue, timeZone: TimeZone.current.identifier))
        } catch {
            stats = .failed(error.localizedDescription)
        }
    }
}

private struct Tile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title2.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct TitleStrip: View {
    let rows: [WatchTitle]
    let movies: Bool
    let baseURL: URL

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(rows, id: \.title) { row in
                    let ref: MediaRef? = movies ? row.movie_id.map(MediaRef.movie) : row.series_id.map(MediaRef.series)
                    let card = VStack(alignment: .leading, spacing: 3) {
                        Poster(path: row.poster, baseURL: baseURL, width: 90, cornerRadius: 10, title: row.title)
                        Text(row.title).font(.caption.weight(.medium)).lineLimit(1)
                        Text("\(row.plays ?? 0) plays").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 90, alignment: .leading)
                    if let ref {
                        NavigationLink(value: ref) { card }.buttonStyle(.plain)
                    } else {
                        card
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .listRowInsets(EdgeInsets())
    }
}

private struct Bars: View {
    let label: String
    let values: [Int]
    let names: [String]

    var body: some View {
        let top = max(1, values.max() ?? 1)
        let peak = WatchStats.peak(values)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let peak, peak < names.count {
                    Text("Busiest: \(names[peak])").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == peak ? Color.accent : Color.accent.opacity(0.35))
                        .frame(height: max(3, CGFloat(value) / CGFloat(top) * 80))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 80, alignment: .bottom)
            .accessibilityHidden(true)
            HStack {
                Text(verbatim: names.first ?? "")
                Spacer()
                Text(verbatim: names.last ?? "")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
