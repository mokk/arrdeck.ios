import ArrdeckData
import SwiftUI

/// The Shows tab's season grid: each show's seasons as toggles, to set
/// monitoring for many at once — tap a season, or "latest only" for a show.
struct SeasonGridView: View {
    let api: any LibraryAPI
    let baseURL: URL
    let query: String
    @State private var rows: Loadable<[SeasonGridRow]> = .loading

    var body: some View {
        Group {
            switch rows {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(all):
                let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = all.filter { needle.isEmpty || ($0.title ?? "").lowercased().contains(needle) }
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.id) { row in
                        GridRow(row: row, baseURL: baseURL) { season, on in await set(row.id, season, on) } latestOnly: {
                            await latestOnly(row)
                        }
                        if row.id != shown.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task { await load() }
    }

    func load() async {
        guard let tools = api as? any ToolsAPI else { rows = .failed("unavailable"); return }
        do { rows = .loaded(try await tools.seasonGrid()) } catch { rows = .failed(error.localizedDescription) }
    }

    /// Updated in place first, so a row of taps does not wait on the server each time.
    func set(_ seriesID: Int, _ season: Int, _ on: Bool) async {
        if case var .loaded(all) = rows, let i = all.firstIndex(where: { $0.id == seriesID }),
           let j = all[i].seasons?.firstIndex(where: { $0.number == season }) {
            all[i].seasons?[j].monitored = on
            rows = .loaded(all)
        }
        try? await api.setSeasonMonitored(series: seriesID, season: season, monitored: on)
    }

    func latestOnly(_ row: SeasonGridRow) async {
        let latest = (row.seasons ?? []).map(\.number).filter { $0 > 0 }.max()
        for season in row.seasons ?? [] where (season.monitored ?? false) != (season.number == latest) {
            await set(row.id, season.number, season.number == latest)
        }
    }
}

private struct GridRow: View {
    let row: SeasonGridRow
    let baseURL: URL
    let toggle: (Int, Bool) async -> Void
    let latestOnly: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(value: MediaRef.series(row.id)) {
                Poster(path: row.poster, baseURL: baseURL, width: 36, cornerRadius: 5, title: row.title ?? "")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Latest only") { Task { await latestOnly() } }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(row.seasons ?? [], id: \.number) { season in
                        let on = season.monitored ?? false
                        Button { Task { await toggle(season.number, !on) } } label: {
                            VStack(spacing: 0) {
                                Text(verbatim: season.number == 0 ? "Sp" : "S\(season.number)").font(.caption.weight(.bold))
                                Text(verbatim: "\(season.have ?? 0)/\(season.total ?? 0)").font(.system(size: 10))
                                    .foregroundStyle((season.total ?? 0) > 0 && (season.have ?? 0) >= (season.total ?? 0) ? Color.success : Color.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(on ? Color.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accent : Color.secondary.opacity(0.3)))
                            .foregroundStyle(on ? Color.accent : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityLabel(Text(season.number == 0 ? String(localized: "Specials") : String(localized: "Season \(season.number)")))
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
