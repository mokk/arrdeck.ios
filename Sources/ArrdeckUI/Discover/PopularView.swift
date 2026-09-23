import ArrdeckData
import SwiftUI

/// Newest releases from each indexer in the last 24 hours, ranked by how
/// often the indexer says they were grabbed.
public struct PopularView: View {
    @State private var model: PopularModel

    public init(api: any DiscoverAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: PopularModel(api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            Section {
                Picker("Kind", selection: $model.kind) {
                    ForEach(PopularKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch model.snapshot {
            case .loading:
                // the fan-out queries every category on every indexer and takes
                // the better part of a minute; say so rather than look stuck
                Section {
                    LoadingRow()
                    Text("Building the first list — this takes about a minute, then it refreshes hourly on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case let .loaded(block):
                switch block {
                case let .offline(reason):
                    Section { ErrorNote("Offline — \(reason)") }
                case let .stale(snapshot, age):
                    Section { StaleNote(age: age) }
                    indexerSections(snapshot)
                case let .healthy(snapshot):
                    indexerSections(snapshot)
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle("Popular")
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("popular")
    }

    @ViewBuilder func indexerSections(_ snapshot: PopularSnapshot) -> some View {
        ForEach(snapshot.indexers ?? [], id: \.indexer_id) { indexer in
            let releases = model.releases(of: indexer)
            Section {
                if releases.isEmpty { EmptyNote("Nothing in this window") }
                ForEach(Array(releases.enumerated()), id: \.offset) { index, release in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(index < 3 ? Color.accent : Color.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(release.title ?? "").font(.subheadline.weight(.medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                StateBadge(state: release.kind == "tv" ? "sonarr" : "radarr")
                                // grabs is the ranking signal, so lead with it
                                Text("\(release.grabs ?? 0) grabs").font(.caption.weight(.semibold))
                                Text(details(release)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(model.grabbed.contains(release.guid ?? "") ? "Grabbed" : "Grab") {
                            Task { await model.grab(release) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(release.guid == nil || model.grabbed.contains(release.guid ?? "") || model.pending.contains(release.guid ?? ""))
                    }
                }
            } header: {
                HStack {
                    Text(indexer.indexer)
                    Spacer()
                    Text("\(indexer.scanned ?? 0) releases in \(snapshot.hours ?? PopularModel.hours)h").textCase(nil)
                }
            }
        }
        Section {
            Text(footer(snapshot)).font(.caption).foregroundStyle(.secondary)
        }
    }

    func details(_ release: PopularRelease) -> String {
        var parts = ["\(release.seeders ?? 0) ↑", Format.bytes(release.size)]
        if let category = release.category { parts.append(category) }
        if let hours = release.hoursOld() {
            parts.append(hours < 1 ? "just now" : "\(Int(hours.rounded()))h ago")
        }
        return parts.joined(separator: " · ")
    }

    func footer(_ snapshot: PopularSnapshot) -> String {
        var text = ""
        if let generated = snapshot.generated_at {
            text = "Updated \(Date(timeIntervalSince1970: TimeInterval(generated)).formatted(.dateTime.hour().minute())) · "
        }
        return text + "Newest releases from each indexer in the last 24 hours, ranked by how often the indexer says they were grabbed. Refreshed every hour."
    }
}
