import ArrdeckAPI
import ArrdeckData
import Foundation
import OpenAPIRuntime
import Testing

@Suite struct DiagnosisTextTests {
    func finding(_ code: String, _ params: [String: (any Sendable)?] = [:]) throws -> DiagnosisFinding {
        DiagnosisFinding(code: code, level: "warning",
                         params: .init(additionalProperties: try OpenAPIObjectContainer(unvalidatedValue: params)))
    }

    @Test func templatesInterpolateParams() throws {
        #expect(try DiagnosisText.sentence(for: finding("queue_stalled", ["state": "stalled"]))
            == "The download has stalled (stalled) — no data is moving.")
        #expect(try DiagnosisText.sentence(for: finding("rss_overdue", ["minutes": 42]))
            == "RSS sync is 42 minutes overdue, so nothing new is being picked up.")
        #expect(try DiagnosisText.sentence(for: finding("indexers_failing", ["count": 1, "message": "down"]))
            == "1 indexer problem reported: down")
    }

    @Test func datedAvailabilityHasItsOwnSentence() throws {
        #expect(try DiagnosisText.sentence(for: finding("not_yet_available", ["availability": "released"]))
            == "Not out yet — the arr waits until it is released.")
        #expect(try DiagnosisText.sentence(for: finding("not_yet_available", ["availability": "released", "date": "Oct 5"]))
            == "Not out yet — the arr waits until it is released, expected Oct 5.")
    }

    @Test func unknownCodeShowsTheCode() throws {
        #expect(try DiagnosisText.sentence(for: finding("something_new")) == "something_new")
        #expect(DiagnosisText.sentence(for: DiagnosisFinding(code: "no_indexers", level: "blocked"))
            == "No indexers are enabled, so there is nowhere to search.")
    }

    @Test func wantedRowsLinkToTheirTitle() {
        #expect(WantedItem(app: .sonarr, id: 4404, library_id: 63, title: "x").ref == .series(63))
        #expect(WantedItem(app: .radarr, id: 180, library_id: 180, title: "x").ref == .movie(180))
    }
}

actor FakeWantedAPI: WantedAPI {
    var pages: [Int: WantedPage]
    var failure: APIError?
    private(set) var calls: [String] = []

    init(pages: [Int: WantedPage]) { self.pages = pages }
    func set(failure: APIError?) { self.failure = failure }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
    private func log(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func wanted(_ app: ArrApp, kind: WantedKind, page: Int) async throws -> WantedPage {
        try log("wanted-\(app.rawValue)-\(kind.rawValue)-\(page)")
        return pages[page] ?? .init(has_more: false, items: [], total: 0)
    }
    func searchAllWanted(_ app: ArrApp, kind: WantedKind) async throws { try log("search-all-\(app.rawValue)-\(kind.rawValue)") }
    func diagnose(_ app: ArrApp, id: Int) async throws -> Diagnosis {
        try log("diagnose-\(id)")
        return .init(app: app.rawValue, findings: [.init(code: "not_monitored", level: "blocked")], id: id)
    }
    func triggerSearch(_ ref: MediaRef) async throws { try log("search-movie-\(ref.id)") }
    func searchEpisodes(_ ids: [Int]) async throws { try log("search-episodes-\(ids.first ?? 0)") }
}

@MainActor
@Suite struct WantedModelTests {
    func item(_ id: Int, app: Components.Schemas.WantedItemOut.appPayload = .sonarr) -> WantedItem {
        .init(app: app, id: id, library_id: 1, title: "t\(id)")
    }

    @Test func pagesAppendAndFiltersReset() async throws {
        let api = FakeWantedAPI(pages: [
            1: .init(has_more: true, items: [item(1), item(2)], total: 3),
            2: .init(has_more: false, items: [item(3)], total: 3),
        ])
        let model = WantedModel(api: api, apps: [.radarr, .sonarr], onSessionLost: {})
        #expect(model.app == .radarr, "the first configured arr is the default")
        await model.load(reset: true)
        #expect(model.items.map(\.id) == [1, 2])
        #expect(model.total == 3)
        #expect(model.hasMore)

        await model.loadMore()
        #expect(model.items.map(\.id) == [1, 2, 3])
        #expect(!model.hasMore)
        await model.loadMore()
        #expect(await api.count("wanted-radarr-missing-2") == 1, "no more pages, no more calls")

        model.kind = .cutoff
        try await Task.sleep(for: .milliseconds(100))
        #expect(await api.count("wanted-radarr-cutoff-1") == 1)
        #expect(model.items.map(\.id) == [1, 2], "reset to page one")
        model.app = .sonarr
        try await Task.sleep(for: .milliseconds(100))
        #expect(await api.count("wanted-sonarr-cutoff-1") == 1)
    }

    @Test func searchPicksTheRightEndpointPerArr() async {
        let api = FakeWantedAPI(pages: [:])
        let model = WantedModel(api: api, apps: [.sonarr], onSessionLost: {})
        await model.search(item(4404, app: .sonarr))
        await model.search(item(180, app: .radarr))
        #expect(await api.count("search-episodes-4404") == 1)
        #expect(await api.count("search-movie-180") == 1)
        await model.searchAll()
        #expect(await api.count("search-all-sonarr-missing") == 1)
        let diagnosis = try? await model.diagnose(item(7))
        #expect(diagnosis?.findings?.first?.code == "not_monitored")
        #expect(await api.count("diagnose-1") == 1, "diagnosed by library id, not episode id")
    }

    @Test func failuresReportAndUnauthorizedEndsTheSession() async {
        let api = FakeWantedAPI(pages: [:])
        await api.set(failure: .unexpectedStatus(500))
        let model = WantedModel(api: api, apps: [.radarr], onSessionLost: {})
        await model.load(reset: true)
        #expect(model.error == "HTTP 500")
        #expect(!model.loading)

        await api.set(failure: .unauthorized)
        var lost = 0
        let gone = WantedModel(api: api, apps: [.radarr], onSessionLost: { lost += 1 })
        await gone.load(reset: true)
        #expect(lost == 1)
        #expect(gone.error == nil)
    }
}
