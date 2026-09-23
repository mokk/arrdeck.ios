import ArrdeckData
import SwiftUI
import UniformTypeIdentifiers

/// Adding a torrent by magnet link, URL, or a .torrent file from the Files
/// picker; a picked file takes precedence over the URL field.
struct AddTorrentSheet: View {
    @State private var model: AddTorrentModel
    @State private var importing = false
    let dismiss: () -> Void

    private static let torrentType = UTType(filenameExtension: "torrent") ?? .data

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
                        .disabled(model.fileData != nil)
                }
                Section("Or a .torrent file") {
                    if let name = model.fileName {
                        HStack {
                            Label(name, systemImage: "doc").lineLimit(1)
                            Spacer()
                            Button("Remove", role: .destructive) { model.clearFile() }
                        }
                    } else {
                        Button { importing = true } label: { Label("Choose file…", systemImage: "folder") }
                            .accessibilityIdentifier("choose-torrent-file")
                    }
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
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.torrentType, .data]) { result in
                switch result {
                case let .success(url):
                    // Files hands out a security-scoped URL; read it once, now.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        model.attach(filename: url.lastPathComponent, data: try Data(contentsOf: url))
                    } catch {
                        model.error = error.localizedDescription
                    }
                case let .failure(error):
                    model.error = error.localizedDescription
                }
            }
        }
    }
}
