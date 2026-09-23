import ArrdeckData
import SwiftUI

/// Settings → Display: how each library shows its titles on this device. The
/// sort menu changes the same layout; this is every tab's choice in one place.
struct DisplaySettingsView: View {
    let apps: [ArrApp]

    var body: some View {
        Form {
            ForEach(apps, id: \.self) { app in
                LibraryDisplaySection(app: app)
            }
            Section {
            } footer: {
                Text("These choices are kept on this device only.")
            }
        }
        .navigationTitle("Display")
    }
}

private struct LibraryDisplaySection: View {
    let app: ArrApp
    @AppStorage private var layout: LibraryLayout
    @AppStorage private var unmonitored: UnmonitoredMode

    init(app: ArrApp) {
        self.app = app
        _layout = AppStorage(wrappedValue: .posters, DisplayKeys.layout(app))
        _unmonitored = AppStorage(wrappedValue: .show, DisplayKeys.unmonitored(app))
    }

    var title: String {
        switch app {
        case .radarr: String(localized: "Movies")
        case .sonarr: String(localized: "Shows")
        case .readarr: String(localized: "Books")
        }
    }

    var body: some View {
        Section(title) {
            Picker("Layout", selection: $layout) {
                ForEach(LibraryLayout.options(for: app), id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Unmonitored titles", selection: $unmonitored) {
                ForEach(UnmonitoredMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }
}
