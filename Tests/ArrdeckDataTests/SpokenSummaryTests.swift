import Foundation
import Testing
@testable import ArrdeckData

/// The wording is checked in English, the development language the tests run
/// in; Danish comes from the catalog at run time.
struct SpokenSummaryTests {
    func torrent(_ name: String, state: String = "downloading", progress: Double = 0.5, speed: Int = 1000) -> Torrent {
        Torrent(client: .qbittorrent, dl_speed: speed, id: name, name: name, progress: progress, size: 1, state: state, ul_speed: 0)
    }

    @Test func nothingMovingSaysSo() {
        #expect(SpokenSummary.downloading([]) == "Nothing is downloading.")
        // seeding is not downloading
        #expect(SpokenSummary.downloading([torrent("A", state: "seeding", speed: 0)]) == "Nothing is downloading.")
    }

    @Test func oneDownloadIsNamedWithItsProgress() {
        let said = SpokenSummary.downloading([torrent("The.Show.S03E08.1080p.WEB.h264-GRP", progress: 0.454)])
        #expect(said == "One download: The Show at 45 percent.")
    }

    @Test func theFastestThreeAreNamedAndTheRestCounted() {
        let said = SpokenSummary.downloading([
            torrent("Slow", speed: 1), torrent("Fast", speed: 9), torrent("Mid", speed: 5),
            torrent("Stalled", state: "stalled", speed: 0), torrent("Queued", state: "queued", speed: 0),
        ])
        #expect(said.hasPrefix("5 downloads: Fast at 50 percent, Mid at 50 percent, Slow at 50 percent"))
        #expect(said.hasSuffix("2 more."))
    }

    @Test func releaseNamesAreCutToTheTitle() {
        #expect(SpokenSummary.spokenName("Dune.Part.Two.2024.2160p.UHD.BluRay.x265-GRP") == "Dune Part Two")
        #expect(SpokenSummary.spokenName("Severance_S02_1080p") == "Severance")
        #expect(SpokenSummary.spokenName("1917.2019.1080p") == "1917", "a title that looks like a year survives")
        #expect(SpokenSummary.spokenName("Plain Name") == "Plain Name")
    }

    @Test func todayListsWhatLandsTodayWithSeasonDropsFolded() {
        let items = [
            CalendarItem(app: .radarr, date: "2026-10-09", item_id: 1, title: "A Film"),
            CalendarItem(app: .sonarr, date: "2026-10-09T08:00:00Z", extra: "S01E01 Pilot", item_id: 2, title: "A Show"),
            CalendarItem(app: .sonarr, date: "2026-10-09T08:00:00Z", extra: "S01E02 Two", item_id: 2, title: "A Show"),
            CalendarItem(app: .radarr, date: "2026-10-10", item_id: 3, title: "Tomorrow's Film"),
        ]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let said = SpokenSummary.today(items, today: "2026-10-09", calendar: utc)
        #expect(said.hasPrefix("Today: A Film"))
        #expect(said.contains("A Show, 2 episodes"))
        #expect(!said.contains("Tomorrow"))
    }

    @Test func anEmptyDaySaysSo() {
        #expect(SpokenSummary.today([], today: "2026-10-09") == "Nothing is out today.")
    }

    @Test func aSignedOutServerIsToldApart() {
        #expect(SpokenSummary.failure(APIError.unauthorized).contains("signed out"))
        #expect(SpokenSummary.failure(URLError(.timedOut)).contains("could not reach"))
    }
}
