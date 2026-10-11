import ArrdeckAPI
import ArrdeckGlance
import Foundation
import Testing
@testable import ArrdeckData

/// The widgets' snapshot from the dashboard's own poll results.
struct GlanceBuilderTests {
    let now = Date(timeIntervalSince1970: 1_791_720_000) // 2026-10-11 12:00 UTC

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func torrent(_ name: String, state: String = "downloading", progress: Double = 0.5, size: Int = 100,
                 down: Int = 1000, up: Int = 0, eta: Int? = 60) -> Torrent {
        Torrent(client: .qbittorrent, dl_speed: down, eta: eta, id: name, name: name, progress: progress,
                size: size, state: state, ul_speed: up)
    }

    func summary(_ active: [Torrent], speed: Int) -> TorrentSummary {
        TorrentSummary(active: active, active_count: active.count, count: 400,
                       totals: .init(dl_speed: speed, ul_speed: 0))
    }

    @Test func seedersAreLeftOutAndTheFastestThreeKept() throws {
        let blocks: [TorrentClient: Block<TorrentSummary>] = [
            .qbittorrent: .healthy(summary([
                torrent("Seeding.Film.2019.1080p", state: "seeding", progress: 1, down: 0, up: 50_000, eta: nil),
                torrent("Slow.Show.S01E01.1080p", down: 10),
                torrent("Fast.Film.2024.2160p", down: 900),
            ], speed: 2000)),
            .transmission: .healthy(summary([
                torrent("Mid.Book", down: 500),
                torrent("Tail.Show.S02E02", down: 1),
            ], speed: 600)),
        ]
        let downloads = try #require(GlanceSnapshot.downloads(blocks, now: now))
        #expect(downloads.count == 4)
        #expect(downloads.top.map(\.name) == ["Fast Film", "Mid Book", "Slow Show"])
        #expect(downloads.speed == 2600, "the clients' totals, not the sum of the top five")
        #expect(downloads.at == now)
    }

    @Test func overallProgressIsWeightedBySize() throws {
        let blocks: [TorrentClient: Block<TorrentSummary>] = [
            .qbittorrent: .healthy(summary([
                torrent("Big", progress: 0.1, size: 900, eta: 900),
                torrent("Small", progress: 1.0, size: 100, eta: 10),
            ], speed: 1)),
        ]
        let downloads = try #require(GlanceSnapshot.downloads(blocks, now: now))
        #expect(abs((downloads.progress ?? 0) - 0.19) < 0.0001)
        #expect(downloads.eta == 900, "the last to finish")
    }

    @Test func noEstimateFromAnyOneMeansNoOverallEstimate() throws {
        let blocks: [TorrentClient: Block<TorrentSummary>] = [
            .qbittorrent: .healthy(summary([torrent("A", eta: 60), torrent("B", eta: 8_640_000)], speed: 1)),
        ]
        let downloads = try #require(GlanceSnapshot.downloads(blocks, now: now))
        #expect(downloads.eta == nil)
        #expect(downloads.top.first { $0.name == "B" }?.eta == nil, "qBittorrent's 100 days is no estimate")
    }

    @Test func nothingMovingIsAnAnswerButEveryClientOfflineIsNot() throws {
        let idle: [TorrentClient: Block<TorrentSummary>] = [.qbittorrent: .healthy(summary([], speed: 0))]
        #expect(try #require(GlanceSnapshot.downloads(idle, now: now)).count == 0)
        let down: [TorrentClient: Block<TorrentSummary>] = [.qbittorrent: .offline("refused"), .transmission: .offline("refused")]
        #expect(GlanceSnapshot.downloads(down, now: now) == nil)
    }

    @Test func todayKeepsTheLocalDayFoldsSeasonsAndCapsAtFour() throws {
        let blocks: [ArrApp: Block<[CalendarItem]>] = [
            .radarr: .healthy([
                CalendarItem(app: "radarr", date: "2026-10-11T00:00:00Z", has_file: true, item_id: 1, title: "A Film"),
                CalendarItem(app: "radarr", date: "2026-10-12T00:00:00Z", item_id: 2, title: "Tomorrow's Film"),
            ]),
            .sonarr: .healthy([
                CalendarItem(app: "sonarr", date: "2026-10-11T08:00:00Z", extra: "S01E01 Pilot", item_id: 3, title: "A Show"),
                CalendarItem(app: "sonarr", date: "2026-10-11T08:00:00Z", extra: "S01E02 Two", item_id: 3, title: "A Show"),
                CalendarItem(app: "sonarr", date: "2026-10-11T20:00:00Z", extra: "S02E05 Five", item_id: 4, title: "B Show"),
                CalendarItem(app: "sonarr", date: "2026-10-11T21:00:00Z", extra: "S03E01 One", item_id: 5, title: "C Show"),
                CalendarItem(app: "sonarr", date: "2026-10-11T22:00:00Z", extra: "S04E01 One", item_id: 6, title: "D Show"),
            ]),
            .readarr: .offline("not configured"),
        ]
        let today = try #require(GlanceSnapshot.today(blocks, now: now, calendar: utc))
        #expect(today.day == "2026-10-11")
        #expect(today.count == 5)
        #expect(today.entries.count == GlanceSnapshot.Today.shown)
        #expect(today.entries.first?.title == "A Film")
        #expect(today.entries.first?.kind == .movie)
        #expect(today.entries.first?.time == nil, "a release day has no time")
        #expect(today.entries.first?.downloaded == true)
        let show = try #require(today.entries.first { $0.title == "A Show" })
        #expect(show.code == "S01E01–E02")
        #expect(show.time == Format.parseDate("2026-10-11T08:00:00Z"))
        #expect(!today.entries.contains { $0.title == "Tomorrow's Film" })
    }

    @Test func theFullestRootFolderIsTheOneShownAndAZeroTotalIsNone() throws {
        let block: Block<[DiskSpace]> = .healthy([
            DiskSpace(free_bytes: 5_000, label: "radarr", path: "/movies", total_bytes: 0),
            DiskSpace(free_bytes: 2_000, label: "sonarr", path: "/tv", total_bytes: 0),
        ])
        let disk = try #require(GlanceSnapshot.disk(block, now: now))
        #expect(disk.free == 2_000)
        #expect(disk.label == "sonarr")
        #expect(disk.total == nil)
        #expect(disk.used == nil, "no total, no gauge")

        let mounted: Block<[DiskSpace]> = .healthy([DiskSpace(free_bytes: 250, path: "/data", total_bytes: 1000)])
        #expect(GlanceSnapshot.disk(mounted, now: now)?.used == 0.75)
        #expect(GlanceSnapshot.disk(.offline("down"), now: now) == nil)
    }

    @Test func anUnansweredCardLeavesItsSectionOut() {
        let snapshot = GlanceSnapshot.make(server: "Home", torrents: nil, calendar: nil, disks: nil, byteBase: 1000, now: now)
        #expect(snapshot.isEmpty)
        #expect(snapshot.byteBase == 1000)
    }
}
