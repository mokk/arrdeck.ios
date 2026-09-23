import ArrdeckData
import SwiftUI

/// Settings → Cleanup: what could go to free disk space. Tick titles, see the
/// total, and delete them with their files — always behind a confirmation.
struct CleanupView: View {
    @State private var model: CleanupModel
    @State private var confirming = false
    @State private var exclude = true
    let baseURL: URL

    init(api: any CleanupAPI, baseURL: URL) {
        _model = State(initialValue: CleanupModel(api: api))
        self.baseURL = baseURL
    }

    var body: some View {
        List {
            Section {
                Picker("List", selection: $model.list) {
                    ForEach(CleanupModel.List.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if model.list == .watched {
                    Picker("Last watched more than", selection: $model.watchedDays) {
                        ForEach([30, 90, 180, 365], id: \.self) { Text("\($0) days ago").tag($0) }
                    }
                }
            } footer: {
                Text("What could go to free space. Tick what to remove; nothing is deleted until you confirm.")
            }
            switch model.lists {
            case .loading: Section { LoadingRow() }
            case let .failed(reason): Section { ErrorNote(reason) }
            case let .loaded(lists):
                let rows = model.rows(model.list)
                if lists.plex != true, model.list == .watched || model.list == .neverWatched {
                    Section { EmptyNote("This list needs Plex, which knows what has been watched.") }
                } else if rows.isEmpty {
                    Section { EmptyNote("Nothing here.") }
                } else {
                    Section {
                        ForEach(rows, id: \.key) { item in row(item) }
                    } header: {
                        Text("\(rows.count) titles · \(Format.bytes(CleanupModel.total(rows)))")
                    }
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle("Cleanup")
        .safeAreaInset(edge: .bottom) {
            if !model.chosen.isEmpty {
                Button(role: .destructive) { confirming = true } label: {
                    Text("Reclaim \(Format.bytes(CleanupModel.total(model.chosen))) (\(model.chosen.count) titles)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .padding()
                .disabled(model.busy)
            }
        }
        .sheet(isPresented: $confirming) { confirmSheet.presentationDetents([.medium]) }
        .alert("Action failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 12) {
            Button { model.toggle(item) } label: {
                Image(systemName: model.picked[item.key] != nil ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(model.picked[item.key] != nil ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Select \(item.title ?? "")"))
            NavigationLink(value: item.ref) {
                HStack(spacing: 10) {
                    Poster(path: item.poster, baseURL: baseURL, width: 34, cornerRadius: 5, title: item.title ?? "")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(reason(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(Format.bytes(item.size)).font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    func reason(_ item: CleanupItem) -> String {
        if model.list == .watched, let last = item.last_viewed_at {
            return String(localized: "Last watched \(Format.when(Date(timeIntervalSince1970: TimeInterval(last))))")
        }
        if model.list == .neverWatched, let added = item.added {
            return String(localized: "Added \(Format.when(added)), never played")
        }
        return item.kind == .movie ? String(localized: "Film") : String(localized: "Show")
    }

    var confirmSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Their files are deleted from disk, freeing about \(Format.bytes(CleanupModel.total(model.chosen))). This cannot be undone.")
                    Toggle("Stop import lists adding them back", isOn: $exclude)
                }
                Section {
                    Button("Delete and free \(Format.bytes(CleanupModel.total(model.chosen)))", role: .destructive) {
                        confirming = false
                        Task { await model.deleteChosen(exclude: exclude) }
                    }
                }
            }
            .navigationTitle("Delete \(model.chosen.count) titles?")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirming = false } } }
        }
    }
}
