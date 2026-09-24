import ArrdeckData
import Foundation
import Testing

actor FakeActivityAPI: ActivityAPI {
    var asked: [Date] = []
    func activitySince(_ since: Date) async throws -> ActivitySince {
        asked.append(since)
        return .init(count: 2, items: [
            .init(app: "sonarr", date: "2026-09-23T10:00:00+00:00", kind: .imported, series_id: 24, title: "S03E08"),
            .init(app: "qbittorrent", date: "2026-09-23T09:00:00+00:00", kind: .completed, title: "some.torrent"),
        ], now: "2026-09-23T12:00:00+00:00", since: since.formatted(.iso8601))
    }
}

@Suite struct ActivityFeedTests {
    func defaults() -> UserDefaults {
        let suite = "activity-feed-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test @MainActor func aFreshInstallBadgesTheLastDayOnly() async {
        let model = ActivityFeedModel(api: FakeActivityAPI(), defaults: defaults(), onSessionLost: {})
        let age = Date.now.timeIntervalSince(model.lastSeen)
        #expect(age > 23 * 3600 && age < 25 * 3600)
        await model.refresh()
        #expect(model.count == 2)
        #expect(model.items.first?.title == "S03E08")
    }

    @Test @MainActor func showingHistoryMovesTheMarkClearsTheBadgeAndPersists() async {
        let store = defaults()
        let model = ActivityFeedModel(api: FakeActivityAPI(), defaults: store, onSessionLost: {})
        await model.refresh()
        #expect(model.count == 2)
        let seen = Date.now
        model.markSeen(at: seen)
        #expect(model.lastSeen == seen)
        #expect(model.count == 0, "the tab badge clears at once")
        model.markSeen(at: seen.addingTimeInterval(-3600))
        #expect(model.lastSeen == seen, "an older moment never moves the mark back")
        let again = ActivityFeedModel(api: FakeActivityAPI(), defaults: store, onSessionLost: {})
        #expect(again.lastSeen == seen, "survives a relaunch")
    }
}
