import ArrdeckAPI
import ArrdeckData
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

/// Answers each path from a table, so the generated client decodes real JSON
/// shapes without a network. Paths are matched without their query string.
struct StubTransport: ClientTransport {
    struct Route: Sendable {
        var status = 200
        var body: String
        var contentType = "application/json"
    }

    let routes: [String: Route]

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = (request.path ?? "").split(separator: "?").first.map(String.init) ?? ""
        guard let route = routes[path] else {
            var response = HTTPResponse(status: .notFound)
            response.headerFields[.contentType] = "text/plain"
            return (response, HTTPBody("no stub for \(path)"))
        }
        var response = HTTPResponse(status: .init(code: route.status))
        response.headerFields[.contentType] = route.contentType
        return (response, HTTPBody(route.body))
    }
}

@Suite struct DecodingTests {
    func api(_ routes: [String: StubTransport.Route]) -> LiveAPI {
        LiveAPI(client: Client(
            serverURL: URL(string: "http://stub")!, transport: StubTransport(routes: routes)
        ))
    }

    /// The regression pin for the derived spec: every one of these fields is
    /// `X | None` on the backend, and the first generated client had none.
    @Test func nullableFieldsRoundTrip() async throws {
        let api = api(["/api/v1/queue": .init(body: """
        {"radarr": {"ok": true, "data": [], "error": null, "stale_age_seconds": null},
         "sonarr": {"ok": true, "data": [{"app": "sonarr", "id": 7, "title": "Show.S01",
           "status": "completed", "tracked_state": "importBlocked", "tracked_status": "warning",
           "size": 100.0, "size_left": 0.0, "time_left": "00:00:00",
           "errors": ["Series title mismatch"], "movie_id": null, "series_id": 3, "episode_id": null}],
           "error": null, "stale_age_seconds": null}}
        """)])
        let queue = try await api.queue()
        #expect(queue[.radarr] == .healthy([]))
        let item = try #require(queue[.sonarr]?.value?.first)
        #expect(item.tracked_state == "importBlocked")
        #expect(item.tracked_status == "warning")
        #expect(item.time_left == "00:00:00")
        #expect(item.series_id == 3)
        #expect(item.movie_id == nil)
    }

    @Test func staleAndOfflineSlicesDecode() async throws {
        let api = api(["/api/v1/torrents/summary": .init(body: """
        {"qbittorrent": {"ok": false, "error": "qbittorrent: 502",
           "data": {"count": 4, "active_count": 0, "totals": {"dl_speed": 0, "ul_speed": 10}, "active": []},
           "stale_age_seconds": 90.5},
         "transmission": {"ok": false, "data": null, "error": "transmission: refused", "stale_age_seconds": null}}
        """)])
        let summary = try await api.torrentSummary()
        #expect(summary[.qbittorrent]?.staleAge == 90.5)
        #expect(summary[.qbittorrent]?.value?.count == 4)
        #expect(summary[.transmission] == .offline("transmission: refused"))
    }

    @Test func recentPostersArriveRelative() async throws {
        let api = api(["/api/v1/dashboard/recent": .init(body: """
        [{"app": "sonarr", "title": "A Show", "subtitle": "S01E06", "date": "2026-09-21T01:18:42Z",
          "poster": "/api/v1/poster?u=https%3A%2F%2Fexample.test%2Fp.jpg", "library_id": 63},
         {"app": "radarr", "title": "A Film", "subtitle": null, "date": "2026-09-20T00:00:00Z",
          "poster": null, "library_id": null}]
        """)])
        let recent = try await api.recent()
        #expect(recent.count == 2)
        #expect(recent[0].poster?.hasPrefix("/api/v1/poster?u=") == true)
        #expect(recent[1].poster == nil)
        #expect(recent[1].library_id == nil)
    }

    @Test func unauthorizedIsItsOwnError() async {
        let api = api(["/api/v1/services": .init(status: 401, body: #"{"detail": "Not authenticated"}"#)])
        await #expect(throws: APIError.unauthorized) { try await api.services() }
    }

    @Test func otherStatusesAndBadBodiesAreDistinct() async {
        let api = api([
            "/api/v1/vpn": .init(status: 502, body: "Bad Gateway", contentType: "text/html"),
            "/api/v1/health": .init(body: "<html>login</html>", contentType: "text/html"),
        ])
        await #expect(throws: APIError.unexpectedStatus(502)) { try await api.vpn() }
        do {
            _ = try await api.health()
            Issue.record("HTML at 200 must not decode")
        } catch let error as APIError {
            if case .transport = error { return }
            Issue.record("expected transport, got \(error)")
        } catch {
            Issue.record("expected APIError, got \(error)")
        }
    }

    @Test func actionsPostToTheRightPaths() async throws {
        let api = api([
            "/api/v1/requests/12/approve": .init(status: 204, body: ""),
            "/api/v1/queue/sonarr/7/blocklist-retry": .init(status: 204, body: ""),
            "/api/v1/subtitles/search": .init(status: 204, body: ""),
        ])
        try await api.act(on: 12, .approve)
        try await api.blocklistRetry(app: .sonarr, id: 7)
        try await api.searchSubtitles(kind: .episode, id: 3, seriesID: 9)
        await #expect(throws: APIError.unexpectedStatus(404)) { try await api.forceImport(app: .radarr, id: 1) }
    }
}
