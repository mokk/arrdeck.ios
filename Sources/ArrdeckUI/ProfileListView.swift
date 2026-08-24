import ArrdeckKit
import SwiftUI

/// The saved servers. Deliberately no edit-URL affordance: the address is the
/// profile's identity (sessions are cookies, passkeys are host-scoped), so a
/// changed address is a new profile — delete and re-add, pairing again.
public struct ProfileListView: View {
    @State private var profiles: [ServerProfile] = []
    @State private var adding = false
    @State private var loadError: String?

    let store: any ProfileStore

    public init(store: any ProfileStore = KeychainProfileStore()) {
        self.store = store
    }

    public var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(profiles) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline)
                    Text(profile.baseURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let info = profile.lastKnown {
                        Text(info.version.isEmpty ? "older backend" : "arrdeck \(info.version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: remove)
        }
        .navigationTitle("Servers")
        .toolbar {
            Button {
                adding = true
            } label: {
                Label("Add server", systemImage: "plus")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AddProfileView { profile in
                    profiles.append(profile)
                    persist()
                    adding = false
                }
            }
        }
        .task { load() }
    }

    func load() {
        do {
            profiles = try store.load()
        } catch {
            // Shown, not swallowed: an unreadable Keychain with saved servers
            // looks identical to a fresh install otherwise.
            loadError = "Could not read saved servers"
        }
    }

    func remove(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
        persist()
    }

    func persist() {
        try? store.save(profiles)
    }
}
