import ArrdeckData
import SwiftUI

/// To read / reading / read on a book's page; "—" clears it.
struct ReadingSection: View {
    let bookID: Int
    let api: any ReadingAPI
    @State private var current: Reading?
    @State private var loaded = false

    var selection: Binding<ReadingStatus?> {
        Binding(get: { current?.readingStatus }, set: { status in
            Task {
                if let map = try? await api.setReading(bookID, status) { current = map[bookID] }
            }
        })
    }

    var body: some View {
        Section {
            Picker("Reading status", selection: selection) {
                Text(verbatim: "—").tag(ReadingStatus?.none)
                ForEach(ReadingStatus.allCases, id: \.self) { Text($0.label).tag(ReadingStatus?.some($0)) }
            }
            .pickerStyle(.segmented)
            if current?.readingStatus == .read, let finished = current?.finished_at {
                Text("Finished \(Format.when(Date(timeIntervalSince1970: TimeInterval(finished))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            current = (try? await api.reading())?[bookID]
        }
    }
}

/// Settings → Reading apps: the OPDS catalogue e-reader apps browse. Its
/// address carries a secret instead of a password.
struct OpdsSettingsView: View {
    let api: any OpdsAPI
    let baseURL: URL
    @State private var settings: Loadable<OpdsSettings> = .loading
    @State private var confirmingNew = false

    var body: some View {
        Form {
            switch settings {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(current):
                if current.available != true {
                    Section { Text("The catalogue needs arrdeck's build of Readarr, which can serve book files.") }
                } else if let url = current.url(on: baseURL) {
                    Section {
                        Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy address") { UIPasteboardShim.copy(url.absoluteString) }
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } header: {
                        Text("Catalogue address")
                    } footer: {
                        Text("Anyone with this address can download your books — treat it like a password.")
                    }
                    Section {
                        Button("New address", role: .destructive) { confirmingNew = true }
                        Button("Turn off", role: .destructive) { Task { await set(false) } }
                    }
                } else {
                    Section {
                        Button("Turn on the catalogue") { Task { await set(true) } }
                    }
                }
            }
            Section {
            } footer: {
                Text("E-reader apps such as KOReader, Moon+ Reader or Thorium can browse the books on disk here and download them. Add the address to the app as an OPDS catalogue.")
            }
        }
        .navigationTitle("Reading apps")
        .confirmationDialog("New address", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("New address", role: .destructive) { Task { await set(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old address stops working; every reading app needs the new one.")
        }
        .task {
            do { settings = .loaded(try await api.opdsSettings()) } catch { settings = .failed(error.localizedDescription) }
        }
    }

    func set(_ enabled: Bool) async {
        do { settings = .loaded(try await api.setOpds(enabled: enabled)) } catch { settings = .failed(error.localizedDescription) }
    }
}

enum UIPasteboardShim {
    @MainActor static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
