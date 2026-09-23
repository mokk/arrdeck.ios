import ArrdeckData
import SwiftUI

/// The PWA's Wanted page: what is missing or below cutoff, per arr, with
/// search, "why hasn't this arrived?" and a link into the title.
public struct WantedView: View {
    @State private var model: WantedModel
    @State private var diagnosing: WantedItem?
    @State private var searching: WantedItem?
    let api: any WantedAPI & LibraryAPI & ExtrasAPI
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void

    public init(
        api: any WantedAPI & LibraryAPI & ExtrasAPI, apps: [ArrApp], baseURL: URL, hasPlex: Bool,
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
        _model = State(initialValue: WantedModel(api: api, apps: apps, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            Section {
                Picker("Kind", selection: $model.kind) {
                    ForEach(WantedKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if model.apps.count > 1 {
                    Picker("App", selection: $model.app) {
                        ForEach(model.apps, id: \.self) { Text(Services.label($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                if let error = model.error {
                    ErrorNote(error)
                }
                if model.items.isEmpty && model.loading {
                    LoadingRow()
                }
                if model.items.isEmpty && !model.loading && model.error == nil {
                    EmptyNote("Nothing here — the library is complete")
                }
                ForEach(model.items, id: \.id) { item in
                    WantedRow(item: item, baseURL: baseURL, model: model, diagnose: { diagnosing = item }, search: { searching = item })
                }
                if model.hasMore {
                    Button(model.loading ? "Loading…" : "Load more") { Task { await model.loadMore() } }
                        .disabled(model.loading)
                }
            } header: {
                HStack {
                    Text("\(model.total) items").accessibilityIdentifier("wanted-count")
                    Spacer()
                    Button("Search all") { Task { await model.searchAll() } }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .disabled(model.isPending("search-all") || model.total == 0)
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle("Wanted")
        .navigationDestination(for: MediaRef.self) { ref in
            switch ref {
            case let .movie(id):
                MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            case let .series(id):
                SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            }
        }
        .task { await model.load(reset: true) }
        .refreshable { await model.load(reset: true) }
        .sheet(item: $diagnosing) { item in
            DiagnoseSheet(app: item.ref?.app ?? .radarr, id: item.library_id,
                          title: [item.title, item.subtitle].compactMap { $0 }.joined(separator: " "), api: api) { diagnosing = nil }
        }
        .sheet(item: $searching) { item in
            ReleasesSheet(
                target: item.app == .radarr ? .movie(item.id) : .episode(series: item.library_id, episode: item.id),
                title: [item.title, item.subtitle].compactMap { $0 }.joined(separator: " "),
                api: api, onSessionLost: onSessionLost
            ) { searching = nil }
        }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("wanted")
    }

    var actionFailed: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

extension WantedItem: Identifiable {}

struct WantedRow: View {
    let item: WantedItem
    let baseURL: URL
    let model: WantedModel
    let diagnose: () -> Void
    let search: () -> Void

    var subtitle: String {
        [item.subtitle, item.air_date.map { Format.day($0) }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: item.ref) {
                HStack(spacing: 10) {
                    Poster(path: item.poster, baseURL: baseURL, width: 36, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .disabled(item.ref == nil)
            Spacer(minLength: 0)
            Button("Search") { Task { await model.search(item) } }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.isPending("search-\(item.id)"))
            Button("Why?", action: diagnose)
                .buttonStyle(.borderless).controlSize(.small)
            Button(action: search) { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("Interactive search")
        }
        .accessibilityIdentifier("wanted-row")
    }
}

/// Answers "why hasn't this arrived?" by reading the queue, the blocklist,
/// the item's own availability, the RSS schedule, delay profiles and indexer
/// health in one go. Worst first, as the endpoint sorts them; the dot is the
/// only colour cue, so it carries the level.
struct DiagnoseSheet: View {
    let app: ArrApp
    let id: Int
    let title: String
    let api: any WantedAPI
    let dismiss: () -> Void
    @State private var diagnosis: Loadable<Diagnosis> = .loading

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch diagnosis {
                    case .loading:
                        LoadingRow()
                    case let .failed(reason):
                        ErrorNote(reason)
                    case let .loaded(result):
                        let findings = result.findings ?? []
                        if findings.isEmpty {
                            EmptyNote(DiagnosisText.nothingFound)
                        }
                        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(levelColor(finding.level)).frame(width: 8, height: 8).padding(.top, 6)
                                Text(DiagnosisText.sentence(for: finding)).font(.subheadline)
                            }
                        }
                    }
                } header: {
                    Text(title)
                }
            }
            .navigationTitle("Why hasn't this arrived?")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do { diagnosis = .loaded(try await api.diagnose(app, id: id)) }
                catch { diagnosis = .failed((error as? APIError)?.description ?? error.localizedDescription) }
            }
        }
    }

    func levelColor(_ level: String) -> Color {
        switch level {
        case "blocked": .red
        case "warning": .orange
        case "info": .blue
        case "ok": .green
        default: .secondary
        }
    }
}
