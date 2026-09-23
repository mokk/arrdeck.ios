import ArrdeckData
import SwiftUI

/// Adding a torrent by magnet link or URL. A .torrent file needs a multipart
/// upload; that arrives with the file importer.
struct AddTorrentSheet: View {
    @State private var model: AddTorrentModel
    let dismiss: () -> Void

    init(clients: [TorrentClient], api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _model = State(initialValue: AddTorrentModel(clients: clients, api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.clients.count > 1 {
                    Picker("Client", selection: $model.client) {
                        ForEach(model.clients, id: \.self) { Text(Services.label($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Magnet link or torrent URL") {
                    TextField("magnet:?xt=…", text: $model.url, axis: .vertical)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                }
                if model.client == .qbittorrent, !model.categories.isEmpty {
                    Picker("Category", selection: $model.category) {
                        Text("(none)").tag("")
                        ForEach(model.categories, id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Start paused", isOn: $model.paused)
                if let error = model.error {
                    Section { ErrorNote(error) }
                }
            }
            .navigationTitle("Add torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.busy ? "…" : "Add") { Task { await model.add() } }
                        .disabled(!model.canSubmit)
                }
            }
            .task { await model.loadCategories() }
            .onChange(of: model.done) { _, done in if done { dismiss() } }
        }
    }
}
