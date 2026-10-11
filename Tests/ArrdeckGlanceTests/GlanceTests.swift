import Foundation
import Testing
@testable import ArrdeckGlance

struct GlanceStoreTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    func snapshot(server: String = "Home") -> GlanceSnapshot {
        GlanceSnapshot(
            server: server,
            downloads: .init(at: now, top: [.init(name: "A Show", progress: 0.5, speed: 1000, eta: 60)],
                             count: 1, speed: 1000, progress: 0.5, eta: 60),
            today: .init(at: now, day: "2026-10-11",
                         entries: [.init(kind: .episode, title: "A Show", code: "S01E02", time: now, downloaded: true)], count: 1),
            disk: .init(at: now, free: 10, total: nil, label: "radarr"),
            byteBase: 1000
        )
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "glance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aWrittenSnapshotReadsBackTheSame() throws {
        let store = GlanceStore(directory: try directory())
        #expect(store.read() == nil, "nothing written yet")
        #expect(store.write(snapshot()))
        #expect(store.read() == snapshot())
    }

    @Test func datesSurviveTheRoundTripToTheSecond() throws {
        let data = try GlanceStore.encode(snapshot())
        let decoded = try #require(GlanceStore.decode(data))
        #expect(decoded.downloads?.at == now)
        #expect(decoded.today?.entries.first?.time == now)
    }

    @Test func anotherVersionOrGarbageReadsAsNothing() throws {
        var other = snapshot()
        other.version = GlanceSnapshot.currentVersion + 1
        #expect(GlanceStore.decode(try GlanceStore.encode(other)) == nil)
        #expect(GlanceStore.decode(Data("not json".utf8)) == nil)
        #expect(GlanceStore.decode(Data("{}".utf8)) == nil)
    }

    @Test func withoutTheAppGroupNothingIsWrittenOrRead() {
        let store = GlanceStore(directory: nil)
        #expect(!store.isAvailable)
        #expect(!store.write(snapshot()))
        #expect(store.read() == nil)
    }

    @Test func aMissingSectionKeepsTheOlderCopyOfIt() {
        let older = snapshot()
        let later = now.addingTimeInterval(30)
        let fresh = GlanceSnapshot(
            server: "Home",
            downloads: .init(at: later, top: [], count: 0, speed: 0, progress: nil, eta: nil)
        )
        let merged = fresh.merging(older)
        #expect(merged.downloads?.count == 0, "the new answer wins")
        #expect(merged.today == older.today, "a section not yet answered keeps the old copy")
        #expect(merged.disk?.at == now, "with its own, older time")
        #expect(merged.takenAt == later)
    }

    @Test func anotherServersCopyIsNotMergedIn() {
        let fresh = GlanceSnapshot(server: "Cabin")
        #expect(fresh.merging(snapshot(server: "Home")).isEmpty)
    }
}

struct FreshnessTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-11 12:00 UTC
    let noon = Date(timeIntervalSince1970: 1_791_720_000)

    func snapshot(at: Date) -> GlanceSnapshot {
        GlanceSnapshot(
            server: "Home",
            downloads: .init(at: at, top: [], count: 0, speed: 0, progress: nil, eta: nil),
            today: .init(at: at, day: GlanceDay.iso(at, calendar: utc), entries: [], count: 0),
            disk: .init(at: at, free: 1, total: nil, label: nil)
        )
    }

    @Test func downloadsDimAfterTenMinutesAndGoAfterTwoHours() {
        let s = snapshot(at: noon)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(9 * 60), calendar: utc) == .fresh)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(10 * 60), calendar: utc) == .stale)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(2 * 3600 - 1), calendar: utc) == .stale)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(2 * 3600), calendar: utc) == .expired)
    }

    @Test func freeSpaceKeepsForDays() {
        let s = snapshot(at: noon)
        #expect(s.freshness(.disk, now: noon.addingTimeInterval(3 * 3600), calendar: utc) == .fresh)
        #expect(s.freshness(.disk, now: noon.addingTimeInterval(2 * 86400), calendar: utc) == .stale)
        #expect(s.freshness(.disk, now: noon.addingTimeInterval(8 * 86400), calendar: utc) == .expired)
    }

    @Test func todayExpiresAtMidnightHoweverRecent() {
        let lateEvening = noon.addingTimeInterval(11 * 3600 + 50 * 60) // 23:50
        let s = snapshot(at: lateEvening)
        #expect(s.freshness(.today, now: lateEvening.addingTimeInterval(5 * 60), calendar: utc) == .fresh)
        #expect(s.freshness(.today, now: lateEvening.addingTimeInterval(15 * 60), calendar: utc) == .expired)
    }

    @Test func aClockSetBackTrustsNothing() {
        let s = snapshot(at: noon)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(-3600), calendar: utc) == .expired)
        #expect(s.freshness(.downloads, now: noon.addingTimeInterval(-10), calendar: utc) == .fresh, "a few seconds of drift is fine")
    }

    @Test func aSectionNeverWrittenHasNoFreshness() {
        #expect(GlanceSnapshot(server: "Home").freshness(.downloads, now: noon) == nil)
    }

    @Test func theTimelineChangesAtEveryLimitAndAtMidnight() {
        let s = snapshot(at: noon)
        let moments = s.transitions(after: noon, calendar: utc)
        #expect(moments == moments.sorted())
        #expect(moments.first == noon.addingTimeInterval(10 * 60), "downloads dim first")
        #expect(moments.contains(noon.addingTimeInterval(2 * 3600)))
        #expect(moments.contains(noon.addingTimeInterval(12 * 3600)), "midnight UTC, when today is over")
        #expect(moments.contains(noon.addingTimeInterval(7 * 86400)))
        #expect(s.transitions(after: noon.addingTimeInterval(8 * 86400), calendar: utc).allSatisfy { $0 > noon.addingTimeInterval(8 * 86400) })
    }
}

struct GlanceLinkTests {
    @Test func everyLinkRoundTrips() {
        for link in GlanceLink.allCases {
            #expect(GlanceLink(url: link.url) == link)
        }
        #expect(GlanceLink.activity.url.absoluteString == "arrdeck://open/activity")
    }

    @Test func theSignInCallbackAndStrangersAreNotLinks() {
        #expect(GlanceLink(url: URL(string: "arrdeck://paired?code=abc")!) == nil)
        #expect(GlanceLink(url: URL(string: "arrdeck://open/nowhere")!) == nil)
        #expect(GlanceLink(url: URL(string: "https://open/activity")!) == nil)
    }
}

struct GlanceFormatTests {
    let en = Locale(identifier: "en_US")

    @Test func bytesFollowTheChosenBase() {
        #expect(GlanceFormat.bytes(1_052_684_484_608, base: 1024, locale: en) == "980.4 GB")
        #expect(GlanceFormat.bytes(1_052_684_484_608, base: 1000, locale: en) == "1.1 TB")
        #expect(GlanceFormat.bytes(0, base: 1024) == "0 B")
        #expect(GlanceFormat.speed(2_500_000, base: 1000, locale: en) == "2.5 MB/s")
    }

    @Test func percentNeverRoundsUpToDone() {
        #expect(GlanceFormat.percent(0.999) == "99%")
        #expect(GlanceFormat.percent(1) == "100%")
        #expect(GlanceFormat.percent(-1) == "0%")
    }
}

struct DownloadsActivityStateTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func nothingDownloadingIsNoActivity() {
        #expect(DownloadsActivityState(nil, byteBase: 1024) == nil)
        #expect(DownloadsActivityState(.init(at: now, top: [], count: 0, speed: 0, progress: nil, eta: nil), byteBase: 1024) == nil)
    }

    @Test func theStateCarriesTheFastestAndTheTime() throws {
        let downloads = GlanceSnapshot.Downloads(
            at: now, top: [.init(name: "Fast", progress: 0.2, speed: 9, eta: 10), .init(name: "Slow", progress: 0.9, speed: 1, eta: 5)],
            count: 2, speed: 10, progress: 0.4, eta: 10
        )
        let state = try #require(DownloadsActivityState(downloads, byteBase: 1000))
        #expect(state.lead == "Fast")
        #expect(state.updatedAt == now)
        #expect(state.count == 2)
    }

    @Test func smallWobblesAreNotWorthResending() {
        let a = DownloadsActivityState(count: 2, speed: 1_000_000, progress: 0.401, eta: 600, lead: "A", updatedAt: now)
        var b = a
        b.updatedAt = now.addingTimeInterval(5)
        b.speed = 1_030_000
        b.progress = 0.405
        #expect(a.looksLike(b))
        b.progress = 0.41
        #expect(!a.looksLike(b), "a whole percent shows")
        b = a
        b.speed = 1_200_000
        #expect(!a.looksLike(b))
        b = a
        b.count = 3
        #expect(!a.looksLike(b))
    }
}
