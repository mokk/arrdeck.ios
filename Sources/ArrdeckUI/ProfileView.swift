import ArrdeckKit
import SwiftUI

/// One profile's standing: where it is, whether it works from here, and the
/// pairing entry point when it does not.
public struct ProfileView: View {
    @State private var session: ProfileSession = .unknown
    @State private var pairing = false

    let profile: ServerProfile
    let transport: any HTTPTransport
    let onUpdate: (ServerProfile) -> Void

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = URLSessionTransport(),
        onUpdate: @escaping (ServerProfile) -> Void
    ) {
        self.profile = profile
        self.transport = transport
        self.onUpdate = onUpdate
    }

    public var body: some View {
        List {
            Section {
                Text(profile.baseURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                statusRow
                    .accessibilityIdentifier("session-status")
            }

            if canPair {
                Section {
                    Button("Sign in") { pairing = true }
                        .accessibilityIdentifier("sign-in")
                } footer: {
                    Text("Opens the server's own sign-in page. Passkeys work there.")
                }
            }

            if let info = SessionFlow.capabilities(of: session) ?? profile.lastKnown,
               !info.features.isEmpty {
                Section("Features") {
                    ForEach(info.features.sorted(), id: \.self) { feature in
                        Text(feature).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .task { await refresh() }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                PairingView(profile: profile) {
                    pairing = false
                    Task { await completePairing() }
                }
                .navigationTitle("Sign in")
            }
        }
    }

    var canPair: Bool {
        switch session {
        case .needsPairing, .rejected: true
        default: false
        }
    }

    @ViewBuilder var statusRow: some View {
        switch session {
        case .unknown:
            Label("Checking…", systemImage: "ellipsis.circle")
        case let .open(info):
            Label("Connected — arrdeck \(info.version), no sign-in needed here",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case let .paired(info):
            Label("Signed in — arrdeck \(info.version)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .legacy:
            Label("Signed in — older backend", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .needsPairing:
            Label("Sign-in required", systemImage: "lock.circle")
                .foregroundStyle(.blue)
        case .rejected:
            Label("Signed out — the session expired or was revoked",
                  systemImage: "lock.slash")
                .foregroundStyle(.orange)
        case let .offline(reason):
            Label("Unreachable: \(reason)", systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case let .notArrdeck(reason):
            Label("Not an arrdeck: \(reason)", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    func refresh() async {
        // Holding a cookie changes the question: not "is this an arrdeck" but
        // "does my session still work" — the 401 answer means signed out, not
        // pair-me.
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        if SessionCookie.match(in: cookies, for: profile.baseURL) != nil {
            await completePairing()
        } else {
            apply(SessionFlow.after(await AboutProbe.probe(profile.baseURL, transport: transport)))
        }
    }

    func completePairing() async {
        let (next, updated) = await Pairing.complete(profile, transport: transport)
        session = next
        if updated != profile { onUpdate(updated) }
    }

    func apply(_ next: ProfileSession) {
        session = next
        if let info = SessionFlow.capabilities(of: next), info != profile.lastKnown {
            var updated = profile
            updated.lastKnown = info
            onUpdate(updated)
        }
    }
}
