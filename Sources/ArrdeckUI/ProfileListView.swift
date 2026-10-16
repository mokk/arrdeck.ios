import ArrdeckDirect
import ArrdeckKit
import SwiftUI

/// The saved profiles, and the root switch between the list and the profile
/// you are in. A profile is a set of services: home, and perhaps a family
/// member's, each with its own connections.
///
/// With exactly one profile saved the app opens straight into it: the list is
/// for choosing, and there is nothing to choose. The profile takes over the
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
        Group {
            if let selected {
                ServerView(profile: selected, onSwitch: { self.selected = nil })
                    .id(selected.id)
            } else {
                NavigationStack { list }
            }
        }
        // the palette and appearance chosen under Settings → Display
        .themed()
    }

    var list: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warning)
            }
            if profiles.isEmpty, loadError == nil {
                Section {
                    Button("Add your services") { adding = true }
                        .accessibilityIdentifier("get-started")
                } footer: {
                    Text("arrdeck talks to Sonarr, Radarr, qBittorrent and the rest itself, with nothing else to host.")
                }
            }
            ForEach(profiles) { profile in
                Button {
                    selected = profile
                } label: {
                    HStack {
                        Text(profile.name).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-row")
            }
            .onDelete(perform: remove)
        }
        .navigationTitle("Profiles")
        .toolbar {
            Button {
                adding = true
            } label: {
                Label("Add profile", systemImage: "plus")
            }
            .accessibilityIdentifier("add-profile")
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
            // Shown, not swallowed: an unreadable Keychain with saved profiles
            // looks identical to a fresh install otherwise.
            loadError = String(localized: "Could not read saved profiles")
        }
    }

    func remove(at offsets: IndexSet) {
        // its service keys and reading statuses go with it
        for profile in offsets.map({ profiles[$0] }) {
            KeychainConnectionStore(profileID: profile.id).delete()
            DefaultsReadingStore.delete(profileID: profile.id)
        }
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
            loadError = String(localized: "Could not save profiles")
        }
    }
}

extension ProfileListView {
    /// For UI tests: one profile with these services, replacing whatever is
    /// saved. `json` maps a service to its fields — `{"radarr": {"url": "…",
    /// "apiKey": "…"}}`, any field left out empty.
    public static func seed(json: Data, store: any ProfileStore = KeychainProfileStore()) {
        guard let raw = try? JSONDecoder().decode([String: [String: String]].self, from: json) else { return }
        let connections = raw.mapValues {
            ServiceConnection(url: $0["url"] ?? "", apiKey: $0["apiKey"] ?? "",
                              username: $0["username"] ?? "", password: $0["password"] ?? "")
        }
        let profile = ServerProfile(name: "Test")
        try? KeychainConnectionStore(profileID: profile.id).save(connections)
        try? store.save([profile])
    }
}
