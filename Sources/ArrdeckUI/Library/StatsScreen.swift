import ArrdeckData
import SwiftUI

/// Eight metrics over 30, 90 or 365 days, as the PWA charts them. Reached
/// from the dashboard's Trends card.
public struct StatsScreen: View {
    enum Mode: String { case library, watching }

    @State private var model: StatsModel
    @AppStorage("stats.view") private var mode: Mode = .library
    let watching: (any WatchingAPI)?
    let baseURL: URL?

    /// With `watching`, a second view of Plex's play history sits beside the library's.
    public init(api: any HistoryAPI, watching: (any WatchingAPI)? = nil, baseURL: URL? = nil,
                onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: StatsModel(api: api, onSessionLost: onSessionLost))
        self.watching = watching
        self.baseURL = baseURL
    }

    public var body: some View {
        List {
            if watching != nil {
                Section {
                    Picker("View", selection: $mode) {
                        Text("Library").tag(Mode.library)
                        Text("Watching").tag(Mode.watching)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let watching, let baseURL, mode == .watching {
                WatchingSections(api: watching, baseURL: baseURL)
            } else {
                librarySections
            }
        }
        .dashboardListStyle()
        .navigationTitle("Statistics")
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("stats")
    }

    @ViewBuilder var librarySections: some View {
            Section {
                Picker("Window", selection: $model.window) {
                    ForEach(StatsWindow.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch model.samples {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case .loaded:
                if model.series.isEmpty {
                    Section { EmptyNote("Not enough samples yet") }
                }
                ForecastSection(forecast: DiskForecast.compute(model.samples.value ?? []))
                ForEach(model.series) { series in
                    Section {
                        StatsChart(series: series, range: model.range)
                    }
                }
            }
    }
}

struct StatsChart: View {
    let series: StatsSeries
    let range: (Date, Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(series.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let range {
                    Text("\(range.0.formatted(.dateTime.month(.abbreviated).day())) → \(range.1.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.format(series.last)).font(.title3.weight(.bold))
                if series.delta != 0 {
                    Text("\(series.delta > 0 ? "+" : "−")\(series.format(abs(series.delta)))")
                        .font(.caption)
                        .foregroundStyle(series.delta > 0 ? Color.success : Color.danger)
                }
            }
            Sparkline(values: series.values)
                .frame(height: 72)
            HStack {
                Text(series.format(series.min)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(series.format(series.max)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Full in about N weeks", at the pace of the window shown.
struct ForecastSection: View {
    let forecast: DiskForecast

    var body: some View {
        switch forecast {
        case .unknown:
            EmptyView()
        case .steady:
            Section("Disk space") { Text("Free space is not shrinking") }
        case let .full(days, perDay):
            Section("Disk space") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(days < 14 ? "Full in about \(max(1, Int(days.rounded()))) days" : "Full in about \(Int((days / 7).rounded())) weeks")
                        .font(.headline)
                    Text("At the pace of this period: \(Format.bytes(Int(perDay))) a day")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
