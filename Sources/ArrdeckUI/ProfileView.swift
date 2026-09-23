import ArrdeckKit
import SwiftUI

/// One profile's connection details: where it is, whether it works from here,
/// and the pairing entry point when it does not. Shown full-screen while the
/// session is unusable, and as a sheet from the dashboard once it is.
public struct ProfileView: View {
    @State private var pairing = false

    let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    var profile: ServerProfile { controller.profile }

    public var body: some View {
        List {
            Section {
                Text(profile.baseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                statusRow
                    .accessibilityIdentifier("session-status")
            }

            if controller.canPair {
                Section {
                    Button("Sign in") { pairing = true }
                        .accessibilityIdentifier("sign-in")
                } footer: {
                    Text("Opens the server's own sign-in page. Passkeys work there.")
                }
            }

            if case .offline = controller.session {
                Section {
                    Button("Try again") { Task { await controller.refresh() } }
                }
            }

            if let info = SessionFlow.capabilities(of: controller.session) ?? profile.lastKnown,
               !info.features.isEmpty {
                Section("Features") {
                    ForEach(info.features.sorted(), id: \.self) { feature in
                        Text(feature).font(.caption.monospaced())
                    }
                }
            }
        }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                PairingView(profile: profile) {
                    pairing = false
                    Task { await controller.completePairing() }
                }
                .navigationTitle("Sign in")
            }
        }
    }

    @ViewBuilder var statusRow: some View {
        switch controller.session {
        case .unknown:
            Label("Checking…", systemImage: "ellipsis.circle")
        case let .open(info):
            Label("Connected — arrdeck \(info.version), no sign-in needed here",
                  systemImage: "checkmark.circle")
                .foregroundStyle(Color.success)
        case let .paired(info):
            Label("Signed in — arrdeck \(info.version)", systemImage: "checkmark.circle")
                .foregroundStyle(Color.success)
        case .legacy:
            Label("Signed in — older backend", systemImage: "checkmark.circle")
                .foregroundStyle(Color.success)
        case .needsPairing:
            Label("Sign-in required", systemImage: "lock.circle")
                .foregroundStyle(Color.accent)
        case .rejected:
            Label("Signed out — the session expired or was revoked",
                  systemImage: "lock.slash")
                .foregroundStyle(Color.warning)
        case let .offline(reason):
            Label("Unreachable: \(reason)", systemImage: "wifi.slash")
                .foregroundStyle(Color.warning)
        case let .notArrdeck(reason):
            Label("Not an arrdeck: \(reason)", systemImage: "xmark.circle")
                .foregroundStyle(Color.danger)
        }
    }
}
