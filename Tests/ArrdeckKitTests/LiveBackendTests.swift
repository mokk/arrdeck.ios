import ArrdeckAPI
import Foundation
import OpenAPIURLSession
import Testing
@testable import ArrdeckKit

/// Opt-in tests against a real backend: ARRDECK_LIVE_URL=http://host:port.
/// Everything else in the suite runs against canned bytes; this is the one
/// place the full URLSession stack and a real arrdeck meet, and it is skipped
/// everywhere that has no backend to hit (CI, other machines).
struct LiveBackendTests {
    static let liveURL = ProcessInfo.processInfo.environment["ARRDECK_LIVE_URL"]

    @Test(.enabled(if: liveURL != nil))
    func theRealBackendAnswersTheProbe() async throws {
        let raw = try #require(Self.liveURL)
        let base = try #require(URL(string: raw))
        let outcome = await AboutProbe.probe(base, transport: ArrdeckKit.URLSessionTransport())
        guard case let .reachable(info) = outcome else {
            Issue.record("expected .reachable from \(base), got \(outcome)")
            return
        }
        #expect(!info.version.isEmpty)
        #expect(info.supports(.diagnose))
    }

    @Test(.enabled(if: liveURL != nil))
    func aNonsensePathOnTheRealBackendIsNotAnArrdeck() async throws {
        // The SPA-fallback trap, proven against the real thing: an unknown path
        // answers 200 HTML, and the probe must not read that as an arrdeck.
        let raw = try #require(Self.liveURL)
        let base = try #require(URL(string: raw))
        let transport = ArrdeckKit.URLSessionTransport()
        let (body, status) = try await transport.get(
            base.appending(path: "/api/v1/definitely-not-a-route")
        )
        #expect(status == 200)
        guard case .notArrdeck = AboutProbe.interpret(status: status, body: body) else {
            Issue.record("SPA fallback was mistaken for an arrdeck response")
            return
        }
    }
}

/// The generated client, end to end: spec → swift-openapi-generator → typed
/// call → real backend. This is the drift alarm in its final form — if the
/// pinned spec and the running backend disagree about /about, this fails.
struct LiveGeneratedClientTests {
    @Test(.enabled(if: LiveBackendTests.liveURL != nil))
    func theGeneratedClientReadsAbout() async throws {
        let raw = try #require(LiveBackendTests.liveURL)
        let base = try #require(URL(string: raw))
        let client = ArrdeckAPI.Client(
            serverURL: base,
            transport: OpenAPIURLSession.URLSessionTransport()
        )
        let response = try await client.about_api_v1_about_get()
        let about = try response.ok.body.json
        #expect(about.name == "arrdeck")
        #expect((about.features ?? []).contains("diagnose"))
    }
}
