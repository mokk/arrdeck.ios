import Foundation
import Testing
@testable import ArrdeckKit

struct PairingWatcherTests {
    let base = URL(string: "https://deck.example.com")!

    func cookie(_ name: String, _ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "tok", .domain: domain, .path: "/"])!
    }

    @Test func firesOnTheSessionCookieForTheRightHost() {
        let watcher = PairingWatcher(for: base)
        let match = watcher.observe([cookie("arrdeck_session", "deck.example.com")])
        #expect(match?.domain == "deck.example.com")
    }

    @Test func firesExactlyOnce() {
        // The caller tears the web view down on the signal; a second fire would
        // tear down whatever replaced it.
        let watcher = PairingWatcher(for: base)
        let hit = [cookie("arrdeck_session", "deck.example.com")]
        #expect(watcher.observe(hit) != nil)
        #expect(watcher.observe(hit) == nil)
    }

    @Test func staysQuietForOtherHostsAndOtherCookies() {
        let watcher = PairingWatcher(for: base)
        #expect(watcher.observe([cookie("arrdeck_session", "10.0.0.154")]) == nil)
        #expect(watcher.observe([cookie("grafana_session", "deck.example.com")]) == nil)
        // And still fires later — the misses above must not consume the shot.
        #expect(watcher.observe([cookie("arrdeck_session", "deck.example.com")]) != nil)
    }
}

struct PairingCompleteTests {
    let aboutJSON = Data("""
    {"name": "arrdeck", "version": "0.2.0", "features": ["diagnose"]}
    """.utf8)

    func profile(lastKnown: BackendInfo? = nil) -> ServerProfile {
        ServerProfile(
            baseURL: URL(string: "https://deck.example.com")!,
            name: "Remote",
            lastKnown: lastKnown
        )
    }

    struct Stub: HTTPTransport {
        var body = Data()
        var status = 200
        var fails = false
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        func get(_ url: URL) async throws -> (Data, Int) {
            if fails { throw Boom() }
            return (body, status)
        }
    }

    @Test func aWorkingReadBecomesPairedAndUpdatesTheProfile() async {
        let (session, updated) = await Pairing.complete(
            profile(), transport: Stub(body: aboutJSON)
        )
        #expect(session == .paired(BackendInfo(version: "0.2.0", features: ["diagnose"])))
        #expect(updated.lastKnown?.version == "0.2.0")
    }

    @Test func aLegacyBackendPairsWithTheEmptyFeatureSet() async {
        let (session, updated) = await Pairing.complete(
            profile(), transport: Stub(body: Data("<!doctype html>".utf8))
        )
        #expect(session == .legacy)
        #expect(updated.lastKnown == .legacy)
    }

    @Test func aRejectedSessionDoesNotWipeWhatTheProfileKnew() async {
        // lastKnown gates the UI while offline; a dead session is not evidence
        // the backend lost its features.
        let known = BackendInfo(version: "0.1.0", features: ["calendar"])
        let (session, updated) = await Pairing.complete(
            profile(lastKnown: known), transport: Stub(status: 401)
        )
        #expect(session == .rejected)
        #expect(updated.lastKnown == known)
    }

    @Test func aTransportFailureIsOfflineAndKeepsTheProfile() async {
        let known = BackendInfo(version: "0.1.0", features: ["calendar"])
        let (session, updated) = await Pairing.complete(
            profile(lastKnown: known), transport: Stub(fails: true)
        )
        #expect(session == .offline("boom"))
        #expect(updated.lastKnown == known)
    }
}
