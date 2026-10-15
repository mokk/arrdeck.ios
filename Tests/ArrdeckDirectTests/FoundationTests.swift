import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

struct EndpointTests {
    @Test func aPathOnTheAddressIsKept() throws {
        // a reverse proxy's /sonarr must survive the API path being added
        let endpoint = try #require(Endpoint("https://media.example.com/sonarr/"))
        #expect(endpoint.url("/api/v3/series").absoluteString == "https://media.example.com/sonarr/api/v3/series")
    }

    @Test func queryValuesAreEncodedAndAPlusStaysAPlus() throws {
        let endpoint = try #require(Endpoint("http://10.0.0.5:8989"))
        let url = endpoint.url("/api/v3/series/lookup", query: ["term": "C++ & you", "skip": nil])
        #expect(url.absoluteString == "http://10.0.0.5:8989/api/v3/series/lookup?term=C%2B%2B%20%26%20you")
    }

    @Test func anAddressWithoutSchemeOrHostIsNoEndpoint() {
        #expect(Endpoint("10.0.0.5:8989") == nil)
        #expect(Endpoint("") == nil)
    }
}

struct ConfiguredTests {
    @Test func anArrNeedsBothAnAddressAndAKey() {
        #expect(!DirectServices.isConfigured("sonarr", ServiceConnection(url: "http://10.0.0.5:8989")))
        #expect(DirectServices.isConfigured("sonarr", .arr()))
    }

    @Test func qbittorrentNeedsOnlyAnAddress() {
        #expect(DirectServices.isConfigured("qbittorrent", ServiceConnection(url: "http://10.0.0.5:8080")))
    }

    @Test func traktNeedsOnlyItsClientID() {
        #expect(DirectServices.isConfigured("trakt", ServiceConnection(apiKey: "abc")))
    }
}

struct KeyedClientTests {
    @Test func theKeyGoesInTheArrsHeader() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/system/status", json: #"{"version": "4.0.1"}"#)
        #expect(try await direct.registry.probeVersion("sonarr") == "4.0.1")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Api-Key") == "secret")
    }

    @Test func aRefusedKeySaysSo() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878", key: "wrong")])
        transport.on("GET /api/v3/system/status", status: 401, json: "")
        await #expect(throws: ServiceUnavailable("radarr", "unauthorized (check API key)")) {
            try await direct.registry.probeVersion("radarr")
        }
    }

    @Test func aGETMeetingA5xxIsTriedOnceMore() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        let calls = Locked(0)
        transport.on("GET /api/v3/system/status") { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return ServiceResponse(status: n == 1 ? 503 : 200, headers: [:], data: Data(#"{"version": "4"}"#.utf8))
        }
        #expect(try await direct.registry.probeVersion("sonarr") == "4")
        #expect(calls.current == 2)
        #expect(direct.registry.retries.count("sonarr") == 1)
    }

    @Test func aPOSTIsNeverSentTwice() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("POST /api/v3/command", status: 503, json: "")
        await #expect(throws: ServiceUnavailable.self) {
            try await direct.registry.arr("sonarr").send("POST", "/command", json: ["name": "RssSync"])
        }
        #expect(transport.requests.count == 1)
    }

    @Test func theArrsOwnWordsComeThroughOnARefusal() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("POST /api/v3/series", status: 400, json: #"[{"errorMessage": "This series has already been added"}]"#)
        await #expect(throws: ServiceRefused(service: "sonarr", status: 400, message: "This series has already been added")) {
            try await direct.registry.arr("sonarr").send("POST", "/series", json: [:])
        }
    }
}

struct TorrentClientTests {
    @Test func qbittorrentLogsInOnA403AndTriesAgain() async throws {
        let (direct, transport) = backend(["qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080", username: "admin", password: "p&ss")])
        let loggedIn = Locked(false)
        transport.on("GET /api/v2/app/version") { _ in
            ServiceResponse(status: loggedIn.current ? 200 : 403, headers: [:], data: Data("v5.0.0".utf8))
        }
        transport.on("POST /api/v2/auth/login") { request in
            loggedIn.withLock { $0 = true }
            #expect(request.value(forHTTPHeaderField: "Referer") == "http://10.0.0.5:8080")
            #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "password=p%26ss&username=admin")
            return ServiceResponse(status: 200, headers: [:], data: Data("Ok.".utf8))
        }
        #expect(try await direct.registry.probeVersion("qbittorrent") == "v5.0.0")
    }

    @Test func qbittorrentWithoutCredentialsSaysSoOnA403() async throws {
        let (direct, transport) = backend(["qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080")])
        transport.on("GET /api/v2/app/version", status: 403, json: "")
        await #expect(throws: ServiceUnavailable("qbittorrent", "403 Forbidden and no credentials configured")) {
            try await direct.registry.probeVersion("qbittorrent")
        }
    }

    @Test func transmissionEchoesTheSessionIDItWasHanded() async throws {
        let (direct, transport) = backend(["transmission": ServiceConnection(url: "http://10.0.0.5:9091")])
        transport.on("POST /transmission/rpc") { request in
            guard request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == "abc" else {
                return ServiceResponse(status: 409, headers: ["X-Transmission-Session-Id": "abc"], data: Data())
            }
            return ServiceResponse(status: 200, headers: [:], data: Data(#"{"result": "success", "arguments": {"version": "4.0.6"}}"#.utf8))
        }
        #expect(try await direct.registry.probeVersion("transmission") == "4.0.6")
        #expect(try await direct.registry.probeVersion("transmission") == "4.0.6")
        // the handshake once, then straight through
        #expect(transport.requests.count == 3)
    }
}

struct ConnectionsTests {
    @Test func servicesListsWhatIsSetUpWithItsWebAddress() async throws {
        let (direct, _) = backend(["sonarr": .arr(), "qbittorrent": ServiceConnection(url: "http://10.0.0.5:8080")])
        let services = try await direct.services()
        let sonarr = try #require(services.first { $0.service == "sonarr" })
        #expect(sonarr.configured)
        #expect(sonarr.web_url == "http://10.0.0.5:8989")
        #expect(services.first { $0.service == "qbittorrent" }?.configured == true)
        #expect(services.first { $0.service == "radarr" }?.configured == false)
        // listed only once set up, as the server does
        #expect(!services.contains { $0.service == "lidarr" })
    }

    @Test func savingTrimsAndReportsWhetherItIsNowConfigured() async throws {
        let (direct, _) = backend([:])
        let configured = try await direct.saveServiceSettings(
            "radarr", url: " http://10.0.0.5:7878/ ", apiKey: " key ", username: "", password: ""
        )
        #expect(configured)
        let saved = try await direct.serviceSettings()["radarr"]
        #expect(saved?.url == "http://10.0.0.5:7878")
        #expect(saved?.api_key == "key")
        #expect(saved?.configured == true)
    }

    @Test func aFailedTestIsTheServicesProblemNotASignOut() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/system/status", status: 401, json: "")
        await #expect(throws: APIError.refused("unauthorized (check API key)")) {
            try await direct.testService("sonarr")
        }
    }

    @Test func statusProbesEveryConfiguredService() async throws {
        let (direct, transport) = backend(["sonarr": .arr(), "radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/system/status") { request in
            request.url?.port == 8989
                ? ServiceResponse(status: 200, headers: [:], data: Data(#"{"version": "4.0"}"#.utf8))
                : ServiceResponse(status: 401, headers: [:], data: Data())
        }
        let status = try await direct.status()
        #expect(status.map(\.service) == ["radarr", "sonarr"])
        #expect(status[0].ok == false)
        #expect(status[0].error == "unauthorized (check API key)")
        #expect(status[1].version == "4.0")
    }
}

struct BlockCacheTests {
    @Test func aDeadServiceShowsItsLastGoodValue() async throws {
        let (direct, _) = backend([:])
        let first: Block<[Int]> = await direct.guarded("k") { [1, 2] }
        #expect(first == .healthy([1, 2]))
        let second: Block<[Int]> = await direct.guarded("k") { throw ServiceUnavailable("sonarr") }
        #expect(second.value == [1, 2])
        #expect(second.staleAge != nil)
    }

    @Test func withNothingCachedItIsOfflineWithTheReason() async throws {
        let (direct, _) = backend([:])
        let block: Block<[Int]> = await direct.guarded("k") { throw ServiceUnavailable("sonarr", "connection refused") }
        #expect(block == .offline("connection refused"))
    }
}

struct JSONTests {
    @Test func fieldsReadByNameAndMissingOnesAreAbsent() throws {
        let json = try JSON(data: Data(#"{"title": "Dune", "year": 2021, "ratings": {"imdb": {"value": 8.1}}, "tags": [1, 2]}"#.utf8))
        #expect(json["title"].string == "Dune")
        #expect(json["year"].int == 2021)
        #expect(json["ratings"]["imdb"]["value"].double == 8.1)
        #expect(json["tags"].array.compactMap(\.int) == [1, 2])
        #expect(json["missing"]["deeper"].string == nil)
    }

    @Test func theArrsTimestampsParseWithOrWithoutFractions() {
        #expect(JSON.string("2024-05-01T12:00:00Z").date != nil)
        #expect(JSON.string("2024-05-01T12:00:00.1234567Z").date != nil)
        #expect(JSON.string("2024-05-01T12:00:00.123Z").date != nil)
    }
}
