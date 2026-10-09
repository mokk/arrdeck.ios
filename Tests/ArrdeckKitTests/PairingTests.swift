import Foundation
import Testing
@testable import ArrdeckKit

struct PairingRequestTests {
    let base = URL(string: "https://deck.example.com")!

    @Test func theChallengeIsTheBackendsPKCEForm() {
        // computed with Python's hashlib, as the backend's _pkce does
        let request = PairingRequest(verifier: "arrdeck-pairing-verifier")
        #expect(request.challenge == "8YtYP9AZEQjZ0-UDJPnlBfd7JJzxgLUrD8Yugsu90GY")
    }

    @Test func eachAttemptGetsItsOwnVerifier() {
        let a = PairingRequest(), b = PairingRequest()
        #expect(a.verifier != b.verifier)
        #expect(a.verifier.count == 43)
        #expect(a.challenge.count == 43)  // the length the backend insists on
    }

    @Test func theLinkOpensThePairPageWithTheChallenge() {
        let request = PairingRequest(verifier: "v")
        let url = request.url(for: base)
        #expect(url.absoluteString == "https://deck.example.com/pair?challenge=\(request.challenge)")
    }

    @Test func theCodeIsReadFromTheRedirect() {
        #expect(PairingRequest.code(from: URL(string: "arrdeck://paired?code=abc-_1")!) == "abc-_1")
    }

    @Test func anythingElseYieldsNoCode() {
        #expect(PairingRequest.code(from: URL(string: "arrdeck://paired")!) == nil)
        #expect(PairingRequest.code(from: URL(string: "arrdeck://paired?code=")!) == nil)
        #expect(PairingRequest.code(from: URL(string: "arrdeck://other?code=abc")!) == nil)
        #expect(PairingRequest.code(from: URL(string: "https://paired?code=abc")!) == nil)
    }
}

struct PairingExchangeTests {
    let base = URL(string: "https://deck.example.com")!

    final class Poster: HTTPPoster, @unchecked Sendable {
        var status: Int
        var sent: (URL, [String: String])?
        init(status: Int) { self.status = status }
        func post(_ url: URL, json: Data) async throws -> (Data, Int) {
            sent = (url, try JSONDecoder().decode([String: String].self, from: json))
            return (Data(), status)
        }
    }

    @Test func sendsTheCodeWithThisAttemptsVerifier() async throws {
        let poster = Poster(status: 200)
        let request = PairingRequest(verifier: "the-verifier")
        try await Pairing.exchange(code: "c0de", request: request, baseURL: base, transport: poster)
        #expect(poster.sent?.0.absoluteString == "https://deck.example.com/api/v1/auth/pair/exchange")
        #expect(poster.sent?.1 == ["code": "c0de", "verifier": "the-verifier"])
    }

    @Test func refusalsAndThrottlingAreTold() async {
        for (status, expected) in [(401, PairingError.refused), (429, .throttled), (500, .unexpected(status: 500))] {
            await #expect(throws: expected) {
                try await Pairing.exchange(
                    code: "c", request: PairingRequest(), baseURL: base, transport: Poster(status: status)
                )
            }
        }
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
