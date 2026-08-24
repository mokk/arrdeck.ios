import Foundation
import Testing
@testable import ArrdeckKit

/// The three-outcome onboarding protocol. Each branch is a claim shown to the
/// user during setup, and two of the server's answers are actively misleading
/// without interpretation: 401 is success-shaped ("an arrdeck, pair first") and
/// 200 can be failure-shaped (the SPA answers 200 HTML for any unknown path).
struct AboutProbeTests {
    let aboutJSON = Data("""
    {"name": "arrdeck", "version": "0.2.0",
     "features": ["diagnose", "credits", "calendar"]}
    """.utf8)

    let spaHTML = Data("<!doctype html>\n<html lang=\"en\"><head></head></html>".utf8)

    @Test func healthyLANBackendIsReachableWithItsCapabilities() throws {
        guard case let .reachable(info) = AboutProbe.interpret(status: 200, body: aboutJSON)
        else { Issue.record("expected .reachable"); return }
        #expect(info.version == "0.2.0")
        #expect(info.supports(.diagnose))
        #expect(!info.supports(.vpn))
    }

    @Test func a401IsAnInvitationToPairNotAFailure() {
        #expect(AboutProbe.interpret(status: 401, body: Data()) == .needsPairing)
    }

    @Test func htmlAt200IsNotAnArrdeckDuringOnboarding() {
        // The SPA fallback answers 200 for any unknown path, so an old backend
        // and a random website look identical here. Onboarding cannot tell them
        // apart — only pairing can — so the honest answer is "not an API".
        guard case let .notArrdeck(reason) = AboutProbe.interpret(status: 200, body: spaHTML)
        else { Issue.record("expected .notArrdeck"); return }
        #expect(reason.contains("web page"))
    }

    @Test func someOtherServicesJSONIsNotAnArrdeck() {
        let radarr = Data(#"{"name": "Radarr", "version": "6.3.0"}"#.utf8)
        guard case .notArrdeck = AboutProbe.interpret(status: 200, body: radarr)
        else { Issue.record("expected .notArrdeck for a different service"); return }
    }

    @Test func otherStatusesReportTheCode() {
        guard case let .notArrdeck(reason) = AboutProbe.interpret(status: 502, body: Data())
        else { Issue.record("expected .notArrdeck"); return }
        #expect(reason == "HTTP 502")
    }

    // MARK: - After pairing, the same bytes mean different things

    @Test func htmlAfterPairingMeansALegacyBackendNotAFailure() {
        // Pairing already proved this is an arrdeck. A 200-HTML /about now means
        // it predates the endpoint — old, not broken.
        #expect(AboutProbe.interpretPaired(status: 200, body: spaHTML) == .legacy)
    }

    @Test func modernBackendReportsItsCapabilitiesAfterPairing() {
        guard case let .current(info) = AboutProbe.interpretPaired(status: 200, body: aboutJSON)
        else { Issue.record("expected .current"); return }
        #expect(info.features.count == 3)
    }

    @Test func a401AfterPairingMeansTheSessionDied() {
        #expect(AboutProbe.interpretPaired(status: 401, body: Data()) == .sessionRejected)
    }

    @Test func proxyErrorAfterPairingDegradesToLegacyRatherThanErroring() {
        #expect(AboutProbe.interpretPaired(status: 502, body: Data()) == .legacy)
    }

    // MARK: - Transport wiring

    struct StubTransport: HTTPTransport {
        let body: Data
        let status: Int
        func get(_ url: URL) async throws -> (Data, Int) { (body, status) }
    }

    struct FailingTransport: HTTPTransport {
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        func get(_ url: URL) async throws -> (Data, Int) { throw Offline() }
    }

    @Test func transportFailureIsUnreachableWithTheReason() async {
        let outcome = await AboutProbe.probe(
            URL(string: "http://10.0.0.154:3500")!,
            transport: FailingTransport()
        )
        #expect(outcome == .unreachable(reason: "offline"))
    }

    @Test func theProbeAsksTheAboutPath() async {
        final class Recorder: HTTPTransport, @unchecked Sendable {
            var asked: URL?
            func get(_ url: URL) async throws -> (Data, Int) {
                asked = url
                return (Data(), 401)
            }
        }
        let recorder = Recorder()
        _ = await AboutProbe.probe(
            URL(string: "https://deck.example.com")!,
            transport: recorder
        )
        #expect(recorder.asked?.absoluteString == "https://deck.example.com/api/v1/about")
    }

    // MARK: - Unknown features survive

    @Test func futureBackendsUnknownFeaturesAreKeptNotDropped() throws {
        let future = Data("""
        {"name": "arrdeck", "version": "3.0.0", "features": ["diagnose", "holograms"]}
        """.utf8)
        guard case let .reachable(info) = AboutProbe.interpret(status: 200, body: future)
        else { Issue.record("expected .reachable"); return }
        // Round-trip through storage encoding: the unknown name must come back.
        let decoded = try JSONDecoder().decode(
            BackendInfo.self, from: JSONEncoder().encode(info)
        )
        #expect(decoded.features.contains("holograms"))
    }
}
