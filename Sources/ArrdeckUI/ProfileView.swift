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
                if let home = profile.homeURL {
                    routeRow(home: home)
                        .accessibilityIdentifier("connection-route")
                }
            }

            if controller.needsAwaySignIn {
                Section {
                    Button("Sign in for away from home") { Task { await signIn() } }
                        .disabled(signingIn)
                        .accessibilityIdentifier("sign-in-away")
                    if let signInError {
                        Text(signInError)
                            .font(.caption)
                            .foregroundStyle(Color.danger)
                    }
                } footer: {
                    Text("No sign-in is needed at home, but \(profile.baseURL.host() ?? profile.baseURL.absoluteString) asks for one. Sign in now and the app keeps working when you leave.")
                }
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

            HomeAddressSection(controller: controller)

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

    /// Which address is in use, shown only with a home address to choose.
    @ViewBuilder func routeRow(home: URL) -> some View {
        switch controller.route {
        case .home:
            Label("At home · \(home.host() ?? home.absoluteString)", systemImage: "house")
        case .primary:
            Label("Away · \(profile.baseURL.host() ?? profile.baseURL.absoluteString)", systemImage: "globe")
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

/// The profile's home address: add, change or remove it. Saved only once it
/// has answered as an arrdeck that needs no sign-in, which is the one answer
/// that would make the app use it — so adding it means being at home.
struct HomeAddressSection: View {
    let controller: SessionController
    var transport: any HTTPTransport = URLSessionTransport()

    @State private var editing = false
    @State private var address = ""
    @State private var probing = false
    @State private var outcome: ProbeOutcome?

    var normalised: URL? { ServerAddress.normalise(address) }
    var primaryHost: String { controller.profile.baseURL.host() ?? controller.profile.baseURL.absoluteString }

    var body: some View {
        Section {
            if let home = controller.profile.homeURL, !editing {
                Text(home.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("home-address")
                Button("Change") {
                    address = home.host().map { host in home.port.map { "\(host):\($0)" } ?? host } ?? ""
                    outcome = nil
                    editing = true
                }
                Button("Remove", role: .destructive) { controller.setHomeURL(nil) }
                    .accessibilityIdentifier("remove-home-address")
            } else if editing || controller.profile.homeURL == nil {
                TextField("10.0.0.154:3500", text: $address)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("home-address-field")
                if let url = normalised, !address.isEmpty {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await check() }
                } label: {
                    if probing { ProgressView() } else { Text("Check and save") }
                }
                .disabled(normalised == nil || probing)
                .accessibilityIdentifier("save-home-address")
                if let outcome, !isSaved(outcome) {
                    rejection(outcome)
                        .accessibilityIdentifier("home-address-outcome")
                }
                if editing {
                    Button("Cancel", role: .cancel) { editing = false; outcome = nil }
                }
            }
        } header: {
            Text("Home address")
        } footer: {
            Text("On your home network the app talks to this address directly, with no sign-in, and uses \(primaryHost) everywhere else. Add it while you are at home.")
        }
    }

    func isSaved(_ outcome: ProbeOutcome) -> Bool {
        if case .reachable = outcome { return true }
        return false
    }

    /// Why this address was not saved. A 401 gets its own words: the address
    /// is an arrdeck, but one that does not trust this network, so the app
    /// would never pick it.
    @ViewBuilder func rejection(_ outcome: ProbeOutcome) -> some View {
        if case .needsPairing = outcome {
            Label("This address asks for sign-in, so it is not a home address the app can use",
                  systemImage: "lock.circle")
                .foregroundStyle(Color.warning)
        } else {
            OutcomeRow(outcome: outcome)
        }
    }

    func check() async {
        guard let url = normalised else { return }
        probing = true
        defer { probing = false }
        let result = await AboutProbe.probe(url, transport: transport)
        outcome = result
        guard isSaved(result) else { return }
        controller.setHomeURL(url)
        editing = false
        address = ""
    }
}
