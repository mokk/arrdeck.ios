import ArrdeckData
import SwiftUI

/// The merged history across both arrs, and the blocklist behind a second
/// segment. Reached from the dashboard's Recent history card.
public struct HistoryScreen: View {
    enum Segment: CaseIterable {
        case history, blocklist
        var label: String {
            switch self {
            case .history: String(localized: "History")
            case .blocklist: String(localized: "Blocklist")
            }
        }
    }
    @State private var model: HistoryModel
    @State private var segment: Segment = .history
    let hasDetail: Bool

    public init(api: any HistoryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        hasDetail = true
        _model = State(initialValue: HistoryModel(api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            Section {
                Picker("Section", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch segment {
            case .history: historySections
            case .blocklist: blocklistSections
            }
        }
        .dashboardListStyle()
        .navigationTitle("History")
        .toolbar {
            if segment == .history {
                Menu {
                    Picker("Service", selection: $model.appFilter) {
                        Text("All").tag(ArrApp?.none)
                        ForEach(ArrApp.allCases, id: \.self) { Text(Services.label($0.rawValue)).tag(ArrApp?.some($0)) }
                    }
                    Picker("Event", selection: $model.eventFilter) {
                        Text("Any event").tag(String?.none)
                        ForEach(historyEventTypes, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filters", systemImage: model.appFilter == nil && model.eventFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .task { await model.load() }
        .task(id: segment) { if segment == .blocklist { await model.loadBlocklist() } }
        .refreshable { await model.load(); await model.loadBlocklist() }
        .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("history")
    }

    @ViewBuilder var historySections: some View {
        Section {
            if let error = model.error { ErrorNote(error) }
            if model.items.isEmpty && model.loading { LoadingRow() }
            if !model.items.isEmpty && model.shown.isEmpty { EmptyNote("No torrents match the filters") }
            ForEach(Array(model.shown.enumerated()), id: \.offset) { _, item in
                NavigationLink(value: item.ref) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            HStack(spacing: 4) {
                                StateBadge(state: item.app.rawValue)
                                ForEach(item.events ?? [], id: \._type) { StateBadge(state: $0._type) }
                                if let quality = item.quality { Text(quality).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer(minLength: 0)
                        Text(Format.dayTime(item.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(item.ref == nil)
            }
            if model.hasMore {
                Button(model.loading ? "Loading…" : "Load more") { Task { await model.loadMore() } }
                    .disabled(model.loading)
            }
        } header: {
            Text("\(model.shown.count) of \(model.items.count)")
        }
    }

    @ViewBuilder var blocklistSections: some View {
        switch model.blocklist {
        case .loading: Section { LoadingRow() }
        case let .failed(reason): Section { ErrorNote(reason) }
        case let .loaded(items):
            if items.isEmpty {
                Section { EmptyNote("Nothing is blocked") }
            } else {
                Section {
                    ForEach(model.blockedApps, id: \.self) { app in
                        Button("Clear \(Services.label(app.rawValue))", role: .destructive) {
                            Task { await model.clearBlocklist(app) }
                        }
                    }
                }
                .disabled(model.busy)
                Section {
                    ForEach(items, id: \.id) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title ?? item.source_title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                                if let source = item.source_title { Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                HStack(spacing: 6) {
                                    StateBadge(state: item.app.rawValue)
                                    Text(([item.quality, item.indexer].compactMap { $0 } + [item.date.map { Format.dayTime($0) }].compactMap { $0 })
                                        .joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Button("Unblock", role: .destructive) { Task { await model.unblock(item) } }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                .disabled(model.busy)
            }
        }
    }
}
