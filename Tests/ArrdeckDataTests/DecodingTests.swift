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

    // A newer server names services and arrs this build has never heard of
    // ("mylar" below). Each such row is dropped; everything else still shows.

    @Test func anUnknownServiceIsSkippedInStatusAndServices() async throws {
        let api = api([
            "/api/v1/status": .init(body: """
            [{"service": "radarr", "ok": true, "version": "6.0"},
             {"service": "mylar", "ok": true, "version": "0.8"},
             {"service": "plex", "ok": false, "error": "refused"}]
            """),
            "/api/v1/services": .init(body: """
            [{"service": "radarr", "configured": true},
             {"service": "mylar", "configured": true, "web_url": "http://mylar.local"},
             {"service": "sonarr", "configured": false}]
            """),
        ])
        #expect(try await api.status().map(\.service) == ["radarr", "plex"])
        #expect(try await api.services().map(\.service) == ["radarr", "sonarr"])
    }

    @Test func aRowFromAnUnknownArrIsDroppedFromItsList() async throws {
        let api = api([
            "/api/v1/queue": .init(body: """
            {"radarr": {"ok": true, "data": [
               {"app": "radarr", "id": 1, "title": "A Film", "status": "downloading", "size": 1, "size_left": 1},
               {"app": "mylar", "id": 2, "title": "A Comic", "status": "downloading", "size": 1, "size_left": 1}]},
             "sonarr": {"ok": false, "data": [
               {"app": "mylar", "id": 3, "title": "Another", "status": "queued", "size": 1, "size_left": 1}],
               "error": "sonarr: 502", "stale_age_seconds": 30},
             "mylar": {"ok": true, "data": []}}
            """),
            "/api/v1/queue/attention": .init(body: """
            {"count": 2, "unavailable": [], "items": [
               {"app": "mylar", "id": 9, "title": "Stuck comic", "status": "completed", "size": 1, "size_left": 0},
               {"app": "sonarr", "id": 7, "title": "Show.S01", "status": "completed", "size": 1, "size_left": 0}]}
            """),
            "/api/v1/calendar": .init(body: """
            {"radarr": {"ok": true, "data": [
               {"app": "mylar", "title": "Issue 4", "date": "2026-10-12"},
               {"app": "radarr", "title": "A Film", "date": "2026-10-12", "item_id": 3}]},
             "sonarr": {"ok": true, "data": []}}
            """),
            "/api/v1/history": .init(body: """
            {"radarr": {"ok": true, "data": [
               {"app": "radarr", "title": "A Film", "date": "2026-10-01T00:00:00Z", "events": []},
               {"app": "mylar", "title": "A Comic", "date": "2026-10-01T00:00:00Z", "events": []}]},
             "sonarr": {"ok": true, "data": []}}
            """),
            "/api/v1/history/all": .init(body: """
            {"has_more": false, "items": [
               {"app": "mylar", "title": "A Comic", "date": "2026-10-01T00:00:00Z", "events": []},
               {"app": "sonarr", "title": "A Show", "date": "2026-10-01T00:00:00Z", "events": []}]}
            """),
            "/api/v1/wanted/radarr": .init(body: """
            {"total": 2, "has_more": false, "items": [
               {"app": "mylar", "id": 1, "library_id": 1, "title": "A Comic"},
               {"app": "radarr", "id": 2, "library_id": 2, "title": "A Film"}]}
            """),
            "/api/v1/dashboard/recent": .init(body: """
            [{"app": "mylar", "title": "A Comic", "date": "2026-10-01T00:00:00Z"},
             {"app": "radarr", "title": "A Film", "date": "2026-10-01T00:00:00Z"}]
            """),
        ])
        let queue = try await api.queue()
        #expect(queue[.radarr]?.value?.map(\.title) == ["A Film"])
        #expect(queue[.sonarr] == .stale([], age: 30), "a stale slice stays stale, minus the row")
        let attention = try await api.attention()
        #expect(attention.items?.map(\.title) == ["Show.S01"])
        #expect(attention.count == 1)
        #expect(try await api.calendar()[.radarr]?.value?.map(\.title) == ["A Film"])
        #expect(try await api.history()[.radarr]?.value?.map(\.title) == ["A Film"])
        #expect(try await api.historyPage(1).items.map(\.title) == ["A Show"])
        #expect(try await api.wanted(.radarr, kind: .missing, page: 1).items.map(\.title) == ["A Film"])
        #expect(try await api.recent().map(\.title) == ["A Film"])
    }

    /// A kind of search result this build has never heard of costs that row,
    /// not the list: the server added artist and album with Lidarr.
    @Test func aSearchResultOfAnUnknownKindIsDroppedFromItsList() async throws {
        let api = api([
            "/api/v1/search/movies": .init(body: """
            [{"kind": "movie", "title": "A Film", "remote_id": 1},
             {"kind": "podcast", "title": "A Show About Films", "remote_id": 2}]
            """),
            "/api/v1/discover/recommendations": .init(body: """
            [{"kind": "podcast", "title": "A Show", "remote_id": 3},
             {"kind": "movie", "title": "Another Film", "remote_id": 4}]
            """),
        ])
        let found = try await api.search(.movies, query: "film")
        #expect(found.map(\.title) == ["A Film"])
        #expect(found.first?.searchKind == .movie)
        #expect(try await api.recommendations().map(\.title) == ["Another Film"])
        #expect(SearchResult(kind: "album", remote_id: 0, title: "Geogaddi").searchKind?.app == .lidarr)
        #expect(SearchResult(kind: "podcast", remote_id: 0, title: "x").searchKind == nil)
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
