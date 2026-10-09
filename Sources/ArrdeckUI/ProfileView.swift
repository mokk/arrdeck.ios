import ArrdeckKit
import AuthenticationServices
import SwiftUI

/// One profile's connection details: where it is, whether it works from here,
/// and the pairing entry point when it does not. Shown full-screen while the
/// session is unusable, and as a sheet from the dashboard once it is.
public struct ProfileView: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var signingIn = false
    @State private var signInError: String?

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
                    Button("Sign in") { Task { await signIn() } }
                        .disabled(signingIn)
                        .accessibilityIdentifier("sign-in")
                    if let signInError {
                        Text(signInError)
                            .font(.caption)
                            .foregroundStyle(Color.danger)
                    }
                } footer: {
                    Text("Opens the server's sign-in page in Safari, where passkeys work, then asks you to pair this phone.")
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
    }

    /// Sign-in runs in the system browser sheet rather than a web view of our
    /// own: passkeys only work in an app's web view for domains it is
    /// entitled to, and this app can point at any server. Ephemeral, so the
    /// sheet skips the "wants to use … to sign in" prompt and keeps nothing.
    func signIn() async {
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        let request = PairingRequest()
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: request.url(for: profile.baseURL),
                callbackURLScheme: PairingRequest.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
            guard let code = PairingRequest.code(from: callback) else { throw PairingError.noCode }
            try await controller.pair(code: code, request: request)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // closed the sheet: nothing to report
        } catch let error as PairingError {
            signInError = message(for: error)
        } catch {
            signInError = error.localizedDescription
        }
    }

    func message(for error: PairingError) -> String {
        switch error {
        case .noCode:
            String(localized: "The sign-in page did not hand back a pairing code.")
        case .refused:
            String(localized: "The pairing code was refused or expired. Sign in again.")
        case .throttled:
            String(localized: "Too many failed attempts. Wait a few minutes and try again.")
        case let .unexpected(status):
            String(localized: "Pairing failed (HTTP \(status)).")
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
