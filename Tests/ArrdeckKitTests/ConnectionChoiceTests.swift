import Foundation
import Testing
@testable import ArrdeckKit

/// Home or away: the one decision behind which address every request uses.
struct ConnectionChoiceTests {
    let home = URL(string: "http://10.0.0.154:3500")!
    let info = BackendInfo(version: "0.2.0", features: ["calendar"])

    @Test func theHomeAddressAnsweringMeansHome() {
        #expect(ConnectionChoice.choose(home: home, probe: .reachable(info)) == .home)
    }

    @Test func theHomeAddressTimingOutMeansThePrimary() {
        #expect(ConnectionChoice.choose(home: home, probe: .unreachable(reason: "timed out")) == .primary)
    }

    @Test func aHomeAddressThatWantsSignInIsNeverChosen() {
        // the backend does not see this caller as local, and no cookie is
        // scoped to the home host: every request there would answer 401
        #expect(ConnectionChoice.choose(home: home, probe: .needsPairing) == .primary)
    }

    @Test func somethingElseAtTheHomeAddressMeansThePrimary() {
        #expect(ConnectionChoice.choose(home: home, probe: .notArrdeck(reason: "HTTP 404")) == .primary)
    }

    @Test func withoutAHomeAddressItIsAlwaysThePrimary() {
        #expect(ConnectionChoice.choose(home: nil, probe: nil) == .primary)
        #expect(ConnectionChoice.choose(home: nil, probe: .reachable(info)) == .primary)
    }

    @Test func aProbeThatTimesOutReadsAsUnreachable() async {
        struct Hanging: HTTPTransport {
            func get(_ url: URL) async throws -> (Data, Int) { throw URLError(.timedOut) }
        }
        let outcome = await ConnectionChoice.probeHome(home, transport: Hanging())
        guard case .unreachable = outcome else { Issue.record("expected .unreachable, got \(outcome)"); return }
        #expect(ConnectionChoice.choose(home: home, probe: outcome) == .primary)
    }

    @Test func theProbeAsksTheHomeAddressForAbout() async {
        final class Recording: HTTPTransport, @unchecked Sendable {
            var asked: [URL] = []
            func get(_ url: URL) async throws -> (Data, Int) {
                asked.append(url)
                return (Data(#"{"name": "arrdeck", "version": "0.2.0", "features": []}"#.utf8), 200)
            }
        }
        let transport = Recording()
        let outcome = await ConnectionChoice.probeHome(home, transport: transport)
        #expect(transport.asked == [URL(string: "http://10.0.0.154:3500/api/v1/about")!])
        #expect(ConnectionChoice.choose(home: home, probe: outcome) == .home)
    }
}
