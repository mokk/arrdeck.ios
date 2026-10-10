import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ArrdeckData

/// Answers every request from `reachable` hosts and fails the rest the way
/// URLSession does when nothing is listening, recording where each went.
final class HostTransport: ClientTransport, @unchecked Sendable {
    let reachable: Set<String>
    let failure: URLError.Code
    private let lock = NSLock()
    private var sent: [String] = []

    init(reachable: Set<String>, failure: URLError.Code = .cannotConnectToHost) {
        self.reachable = reachable
        self.failure = failure
    }

    var hosts: [String] { lock.withLock { sent } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let host = baseURL.host() ?? ""
        lock.withLock { sent.append(host) }
        guard reachable.contains(host) else { throw URLError(failure) }
        if request.method == .post { return (HTTPResponse(status: .noContent), nil) }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody("[]"))
    }
}

@Suite struct AddressRouterTests {
    let primary = URL(string: "https://deck.example.com")!
    let home = URL(string: "http://10.0.0.154:3500")!

    func atHome() -> AddressRouter {
        let router = AddressRouter(primary: primary, home: home)
        router.use(home: true)
        return router
    }

    @Test func requestsGoWhereTheRouterPoints() async throws {
        let router = atHome()
        let transport = HostTransport(reachable: ["10.0.0.154", "deck.example.com"])
        let api = LiveAPI(router: router, transport: transport)
        _ = try await api.services()
        router.use(home: false)
        _ = try await api.services()
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com"])
    }

    @Test func anUnreachableHomeAddressFallsBackOnceAndStaysThere() async throws {
        let router = atHome()
        let fellBack = Counter()
        router.setOnFallback { fellBack.bump() }
        let transport = HostTransport(reachable: ["deck.example.com"])
        let api = LiveAPI(router: router, transport: transport)

        _ = try await api.services()
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com"])
        #expect(!router.isHome)
        #expect(fellBack.value == 1)

        // the next request does not try home again
        _ = try await api.services()
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com", "deck.example.com"])
        #expect(fellBack.value == 1)
    }

    @Test func aFailureOnThePrimaryIsNotRetried() async {
        let router = atHome()
        let transport = HostTransport(reachable: [])
        let api = LiveAPI(router: router, transport: transport)
        // home, then primary once — not home again, not primary twice
        await #expect(throws: APIError.self) { try await api.services() }
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com"])
        await #expect(throws: APIError.self) { try await api.services() }
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com", "deck.example.com"])
    }

    @Test func withoutAHomeAddressNothingFallsBack() async {
        let router = AddressRouter(primary: primary)
        router.use(home: true)
        #expect(!router.isHome)
        let transport = HostTransport(reachable: [])
        let api = LiveAPI(router: router, transport: transport)
        await #expect(throws: APIError.self) { try await api.services() }
        #expect(transport.hosts == ["deck.example.com"])
    }

    @Test func aPostThatNeverConnectedIsRetried() async throws {
        let transport = HostTransport(reachable: ["deck.example.com"], failure: .cannotConnectToHost)
        let api = LiveAPI(router: atHome(), transport: transport)
        try await api.searchSubtitles(kind: .movie, id: 1, seriesID: nil)
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com"])
    }

    @Test func aPostThatMayHaveArrivedIsNotSentTwice() async {
        // a timeout can come after the backend acted: grabbing a release twice
        // is worse than one error — but the router still leaves home
        let router = atHome()
        let transport = HostTransport(reachable: ["deck.example.com"], failure: .timedOut)
        let api = LiveAPI(router: router, transport: transport)
        await #expect(throws: APIError.self) { try await api.searchSubtitles(kind: .movie, id: 1, seriesID: nil) }
        #expect(transport.hosts == ["10.0.0.154"])
        #expect(!router.isHome)
    }

    @Test func aGetThatTimedOutAtHomeIsRetried() async throws {
        let transport = HostTransport(reachable: ["deck.example.com"], failure: .timedOut)
        let api = LiveAPI(router: atHome(), transport: transport)
        _ = try await api.services()
        #expect(transport.hosts == ["10.0.0.154", "deck.example.com"])
    }

    @Test func removingTheHomeAddressMovesToThePrimary() {
        let router = atHome()
        router.setHome(nil)
        #expect(router.current == primary)
        #expect(!router.isHome)
    }

    @Test func otherErrorsDoNotFallBack() {
        #expect(RoutingTransport.unreached(URLError(.cancelled)) == nil)
        #expect(RoutingTransport.unreached(URLError(.secureConnectionFailed)) == nil)
        #expect(RoutingTransport.unreached(APIError.unauthorized) == nil)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
