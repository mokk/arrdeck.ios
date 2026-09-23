import ArrdeckKit
import SwiftUI

/// Onboarding: type an address, probe it, and show one of the three honest
/// outcomes. The 401 branch is deliberately presented as progress ("found it,
/// pairing comes next"), because to a user a 401 that looks like an error reads
/// as a typo in the address.
public struct AddProfileView: View {
    @State private var address = ""
    @State private var name = ""
    @State private var probing = false
    @State private var outcome: ProbeOutcome?

    let transport: any HTTPTransport
    let onCreate: (ServerProfile) -> Void

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        onCreate: @escaping (ServerProfile) -> Void
    ) {
        self.transport = transport
        self.onCreate = onCreate
    }

    var normalised: URL? { ServerAddress.normalise(address) }

    public var body: some View {
        Form {
            Section("Server") {
                TextField("deck.example.com or 10.0.0.154:3500", text: $address)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("server-address")
                if let url = normalised, !address.isEmpty {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                TextField("Name (optional)", text: $name)
            }

            Section {
                Button {
                    Task { await probe() }
                } label: {
                    if probing {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(normalised == nil || probing)
                .accessibilityIdentifier("connect")
            }

            if let outcome {
                Section {
                    OutcomeRow(outcome: outcome)
                        .accessibilityIdentifier("probe-outcome")
                    if canCreate(outcome) {
                        Button("Save server") { create(outcome) }
                            .accessibilityIdentifier("save-server")
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Add server")
    }

    func probe() async {
        guard let url = normalised else { return }
        probing = true
        outcome = await AboutProbe.probe(url, transport: transport)
        probing = false
    }

    /// Reachable and needs-pairing both produce a profile; pairing itself is
    /// phase C and happens from the profile afterwards.
    func canCreate(_ outcome: ProbeOutcome) -> Bool {
        switch outcome {
        case .reachable, .needsPairing: return true
        case .notArrdeck, .unreachable: return false
        }
    }

    func create(_ outcome: ProbeOutcome) {
        guard let url = normalised else { return }
        var info: BackendInfo?
        if case let .reachable(reached) = outcome { info = reached }
        let fallbackName = url.host() ?? url.absoluteString
        onCreate(
            ServerProfile(
                baseURL: url,
                name: name.isEmpty ? fallbackName : name,
                lastKnown: info
            )
        )
    }
}

struct OutcomeRow: View {
    let outcome: ProbeOutcome

    var body: some View {
        switch outcome {
        case let .reachable(info):
            Label("arrdeck \(info.version) — no sign-in needed here", systemImage: "checkmark.circle")
                .foregroundStyle(Color.success)
        case .needsPairing:
            Label("Found an arrdeck — it will ask you to sign in", systemImage: "lock.circle")
                .foregroundStyle(Color.accent)
        case let .notArrdeck(reason):
            Label("Not an arrdeck: \(reason)", systemImage: "xmark.circle")
                .foregroundStyle(Color.danger)
        case let .unreachable(reason):
            Label("Could not reach it: \(reason)", systemImage: "wifi.slash")
                .foregroundStyle(Color.warning)
        }
    }
}
