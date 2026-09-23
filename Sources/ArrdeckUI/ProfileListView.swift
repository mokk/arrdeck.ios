import ArrdeckKit
import SwiftUI

/// The saved servers, and the root switch between the list and the server
/// you are in. Deliberately no edit-URL affordance: the address is the
/// profile's identity (sessions are cookies, passkeys are host-scoped), so a
/// changed address is a new profile — delete and re-add, pairing again.
///
/// With exactly one server saved the app opens straight into it: the list is
/// for choosing, and there is nothing to choose. The server takes over the
/// whole window (its tabs each carry their own navigation stack) rather than
/// being pushed, because a TabView does not belong inside a pushed screen.
public struct ProfileListView: View {
    @State private var profiles: [ServerProfile] = []
    @State private var selected: ServerProfile?
    @State private var adding = false
    @State private var loadError: String?

    let store: any ProfileStore

    public init(store: any ProfileStore = KeychainProfileStore()) {
        self.store = store
    }

    public var body: some View {
        if let selected {
            ServerView(profile: selected, onUpdate: update, onSwitch: { self.selected = nil })
                .id(selected.id)
        } else {
            NavigationStack { list }
        }
    }

    var list: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(profiles) { profile in
                Button {
                    selected = profile
                } label: {
                    HStack {
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
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-row")
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
            .accessibilityIdentifier("add-server")
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
            if profiles.count == 1, let only = profiles.first {
                selected = only
            }
        } catch {
            // Shown, not swallowed: an unreadable Keychain with saved servers
            // looks identical to a fresh install otherwise.
            loadError = "Could not read saved servers"
        }
    }

    func update(_ updated: ServerProfile) {
        if let at = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[at] = updated
            persist()
        }
    }

    func remove(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
        persist()
    }

    func persist() {
        do {
            try store.save(profiles)
            loadError = nil
        } catch {
            // Surfaced, not swallowed: a silent save failure looks like working
            // persistence until the next launch, which is the worst time to
            // find out. (Found exactly that way: an unsigned simulator build
            // has no keychain access, and try? hid it.)
            loadError = "Could not save servers"
        }
    }
}
