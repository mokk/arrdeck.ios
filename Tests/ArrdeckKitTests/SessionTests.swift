import Foundation
import Testing
@testable import ArrdeckKit

/// The session flow is the vocabulary the pairing screen and the shell speak.
struct SessionTests {
    let info = BackendInfo(version: "0.2.0", features: ["diagnose"])

    @Test func lanBackendOpensWithoutPairing() {
        #expect(SessionFlow.after(.reachable(info)) == .open(info))
    }

    @Test func a401BecomesAPairingOffer() {
        #expect(SessionFlow.after(ProbeOutcome.needsPairing) == .needsPairing)
    }

    @Test func pairedReadYieldsCapabilities() {
        #expect(SessionFlow.after(.current(info)) == .paired(info))
    }

    @Test func aDeadSessionIsRejectedNotNew() {
        // "Signed out" and "never signed in" read differently to a person; the
        // UI must be able to tell them apart.
        #expect(SessionFlow.after(PairedAbout.sessionRejected) == .rejected)
        #expect(SessionFlow.after(PairedAbout.sessionRejected) != .needsPairing)
    }

    @Test func onlyWorkingStatesCarryCapabilities() {
        #expect(SessionFlow.capabilities(of: .open(info)) == info)
        #expect(SessionFlow.capabilities(of: .paired(info)) == info)
        #expect(SessionFlow.capabilities(of: .legacy) == .legacy)
        #expect(SessionFlow.capabilities(of: .needsPairing) == nil)
        #expect(SessionFlow.capabilities(of: .rejected) == nil)
        #expect(SessionFlow.capabilities(of: .offline("x")) == nil)
    }
}

/// Cookie matching: the shared web-view store holds cookies from every profile
/// ever paired, so picking the right one is a correctness question, not lookup.
struct SessionCookieTests {
    func cookie(name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: "tok", .domain: domain, .path: "/",
        ])!
    }

    @Test func picksTheCookieForTheRightHost() {
        let cookies = [
            cookie(name: "arrdeck_session", domain: "10.0.0.154"),
            cookie(name: "arrdeck_session", domain: "deck.example.com"),
        ]
        let match = SessionCookie.match(
            in: cookies, for: URL(string: "https://deck.example.com")!
        )
        #expect(match?.domain == "deck.example.com")
    }

    @Test func anotherProfilesCookieIsNeverBorrowed() {
        // Handing profile A's cookie to profile B would "work" until the
        // backend rejected it in a way the UI reads as a dead session on A.
        let cookies = [cookie(name: "arrdeck_session", domain: "10.0.0.154")]
        #expect(
            SessionCookie.match(in: cookies, for: URL(string: "https://deck.example.com")!) == nil
        )
    }

    @Test func unrelatedCookiesOnTheSameHostAreIgnored() {
        let cookies = [cookie(name: "grafana_session", domain: "deck.example.com")]
        #expect(
            SessionCookie.match(in: cookies, for: URL(string: "https://deck.example.com")!) == nil
        )
    }

    @Test func theNameMatchesWhatTheBackendSets() throws {
        // Contract check against the pinned backend source, same move as the
        // FEATURE_ROUTES test: the cookie name lives in auth.py, and a rename
        // there must fail here rather than break pairing at runtime.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let auth = dir.appending(path: "arrdeck/backend/app/api/v1/auth.py")
        let source = try String(contentsOf: auth, encoding: .utf8)
        #expect(source.contains("\"\(SessionCookie.name)\""))
    }
}
