import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

actor FakeHistoryAPI: HistoryAPI {
    var pages: [Int: HistoryPage]
    var blocked: [BlocklistItem] = [
        .init(app: "radarr", id: 1, title: "A"), .init(app: "radarr", id: 2, title: "B"),
    ]
    private(set) var calls: [String] = []
    init(pages: [Int: HistoryPage]) { self.pages = pages }
    func count(_ c: String) -> Int { calls.filter { $0 == c }.count }
    private func log(_ c: String) { calls.append(c) }

    func historyPage(_ page: Int) async throws -> HistoryPage {
        log("history-\(page)")
        return pages[page] ?? .init(has_more: false, items: [])
    }
    func blocklist() async throws -> BlocklistPage { log("blocklist"); return .init(items: blocked) }
    func removeFromBlocklist(_ app: ArrApp, id: Int) async throws {
        log("unblock-\(app.rawValue)-\(id)")
        blocked.removeAll { $0.id == id }
    }
    func clearBlocklist(_ app: ArrApp) async throws {
        log("clear-\(app.rawValue)")
        blocked.removeAll { $0.arr == app }
    }
}

@MainActor
@Suite struct HistoryStatsTests {
    func item(_ app: ArrApp, _ events: [String], date: String = "2026-09-20T00:00:00Z") -> HistoryItem {
        .init(app: app.rawValue, date: date, events: events.map { .init(date: date, _type: $0) }, title: "t")
    }

    @Test func historyPagesAppendAndFilterLocally() async {
        let api = FakeHistoryAPI(pages: [
            1: .init(has_more: true, items: [item(.radarr, ["fetched", "imported"]), item(.sonarr, ["fetched"])]),
            2: .init(has_more: false, items: [item(.sonarr, ["failed"])]),
        ])
        let model = HistoryModel(api: api)
        await model.load()
        #expect(model.items.count == 2)
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.items.count == 3)
        #expect(!model.hasMore)

        model.appFilter = .sonarr
        #expect(model.shown.count == 2)
        model.eventFilter = "failed"
        #expect(model.shown.count == 1)
        model.appFilter = nil
        model.eventFilter = "imported"
        #expect(model.shown.count == 1)

        await model.load()
        #expect(model.items.count == 2, "reload starts from page one")
        #expect(await api.count("history-1") == 2)
    }

    @Test func blocklistUnblockAndClearRefetch() async {
        let api = FakeHistoryAPI(pages: [:])
        let model = HistoryModel(api: api)
        await model.loadBlocklist()
        #expect(model.blocklist.value?.count == 2)
        #expect(model.blockedApps == [.radarr])
        await model.unblock(model.blocklist.value![0])
        #expect(await api.count("unblock-radarr-1") == 1)
        #expect(model.blocklist.value?.count == 1)
        await model.clearBlocklist(.radarr)
        #expect(model.blocklist.value?.isEmpty == true)
        #expect(model.blockedApps.isEmpty)
    }
}
