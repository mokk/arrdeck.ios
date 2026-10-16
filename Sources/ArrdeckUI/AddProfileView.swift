import ArrdeckKit
import SwiftUI

/// A new profile: a name for a set of services. Their addresses and keys come
/// next, under Connections, which opens by itself on a profile with none.
public struct AddProfileView: View {
    @State private var name = ""

    let onCreate: (ServerProfile) -> Void

    public init(onCreate: @escaping (ServerProfile) -> Void) {
        self.onCreate = onCreate
    }

    public var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name)
                    .accessibilityIdentifier("profile-name")
            } footer: {
                Text("The app talks to Sonarr, Radarr, qBittorrent and the rest itself. You add their addresses and API keys next.")
            }
            Section {
                Button("Add") { create() }
                    .accessibilityIdentifier("save-profile")
            }
        }
        .themedList()
        .navigationTitle("Add profile")
    }

    func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(ServerProfile(name: trimmed.isEmpty ? String(localized: "My services") : trimmed))
    }
}
