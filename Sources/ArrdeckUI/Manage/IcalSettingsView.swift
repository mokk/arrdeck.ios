import ArrdeckData
import SwiftUI

/// Settings → Calendar subscription: one address Calendar, Google Calendar or
/// Outlook subscribes to, with Radarr, Sonarr and Readarr merged. Like the OPDS
/// feed it carries a secret, since calendar apps cannot sign in.
struct IcalSettingsView: View {
    let api: any IcalAPI
    let baseURL: URL
    @State private var settings: Loadable<IcalSettings> = .loading
    @State private var left: Set<String> = []
    @State private var confirmingNew = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            switch settings {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(current):
                let apps = current.apps ?? []
                let chosen = apps.filter { !left.contains($0) }
                if apps.isEmpty {
                    Section { Text("The calendar needs Radarr, Sonarr or Readarr.") }
                } else if let url = current.url(on: baseURL, apps: chosen) {
                    if apps.count > 1 {
                        Section("Include") {
                            ForEach(apps, id: \.self) { app in
                                Toggle(Services.label(app), isOn: Binding(
                                    get: { !left.contains(app) },
                                    set: { on in if on { left.remove(app) } else if chosen.count > 1 { left.insert(app) } }
                                ))
                            }
                        }
                    }
                    Section {
                        Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        if let webcal = current.webcal(on: baseURL, apps: chosen) {
                            Button { openURL(webcal) } label: { Label("Subscribe in Calendar", systemImage: "calendar.badge.plus") }
                        }
                        Button("Copy address") { UIPasteboardShim.copy(url.absoluteString) }
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } header: {
                        Text("Calendar address")
                    } footer: {
                        Text("Anyone with this address can see what is coming up — treat it like a password.")
                    }
                    Section {
                        Button("New address", role: .destructive) { confirmingNew = true }
                        Button("Turn off", role: .destructive) { Task { await set(false) } }
                    }
                } else {
                    Section {
                        Button("Turn on the calendar") { Task { await set(true) } }
                    }
                }
            }
            Section {
            } footer: {
                Text("Subscribe to what Radarr, Sonarr and Readarr have coming in Calendar, Google Calendar or Outlook — one calendar for all of them.")
            }
        }
        .themedList()
        .navigationTitle("Calendar subscription")
        .confirmationDialog("New address", isPresented: $confirmingNew, titleVisibility: .visible) {
            Button("New address", role: .destructive) { Task { await set(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old address stops working; every calendar app needs the new one.")
        }
        .task {
            do { settings = .loaded(try await api.icalSettings()) } catch { settings = .failed(error.localizedDescription) }
        }
    }

    func set(_ enabled: Bool) async {
        do { settings = .loaded(try await api.setIcal(enabled: enabled)) } catch { settings = .failed(error.localizedDescription) }
    }
}
