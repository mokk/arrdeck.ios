import ArrdeckAPI
import ArrdeckGlance
import Foundation
import Testing
@testable import ArrdeckData

/// The Activity widget's entries from Activity's feed: one event per record,
/// so one per episode where the dashboard's history has one per torrent.
struct ActivityGlanceTests {
    let now = Date(timeIntervalSince1970: 1_791_720_000) // 2026-10-11 12:00 UTC

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func event(_ kind: ActivityEvent.kindPayload, _ app: String, _ title: String, _ date: String,
               movie: Int? = nil, series: Int? = nil, book: Int? = nil,
               season: Int? = nil, episode: Int? = nil) -> ActivityEvent {
        ActivityEvent(app: app, book_id: book, date: date, episode: episode, kind: kind, movie_id: movie,
                      season: season, series_id: series, title: title)
    }

    func activity(_ events: [ActivityEvent], titles: [MediaRef: GlanceTitle] = [:],
                  posters: Set<String> = []) -> [GlanceSnapshot.Activity.Entry] {
        GlanceSnapshot.activity(events, titles: titles, posters: posters, now: now, calendar: utc).entries
    }

    @Test func aGrabAndItsImportAreOneArrival() {
        let entries = activity([
            event(.fetched, "radarr", "Animals.2026.NORDiC.1080p.NF.WEB-DL.H.264-NORViNE", "2026-10-09T15:18:04Z", movie: 207),
            event(.imported, "radarr", "Animals.2026.NORDiC.1080p.NF.WEB-DL.H.264-NORViNE", "2026-10-09T15:21:03Z", movie: 207),
        ])
        #expect(entries.count == 1)
        #expect(entries[0].event == .arrived)
        #expect(entries[0].kind == .movie)
        #expect(entries[0].title == "Animals", "the release name cleaned up")
        #expect(entries[0].code == nil)
        #expect(entries[0].key == "movie-207")
        #expect(entries[0].date == ISO8601DateFormatter().date(from: "2026-10-09T15:21:03Z"))
    }

    @Test func twoSeasonPacksNameEveryEpisode() {
        // the first season's pack names no episode; the server says which
        let first = (1...8).map { (n: Int) in
            event(.imported, "sonarr", "Mayfair Witches 2023 S01 1080p REPACK Blu-ray DDP 5 1 x265 - YELLO",
                  "2026-10-10T20:1\(n):00Z", series: 86, season: 1, episode: n)
        }
        let second = (1...8).map { (n: Int) in
            event(.imported, "sonarr", "Mayfair.Witches.S02E0\(n).1080p.BluRay.x264-TABULARiA",
                  "2026-10-10T20:2\(n):00Z", series: 86, season: 2, episode: n)
        }
        let grabs = [event(.fetched, "sonarr", "Mayfair Witches 2023 S01", "2026-10-10T20:05:00Z", series: 86)]
        let entries = activity(first + second + grabs,
                               titles: [.series(86): GlanceTitle(title: "Anne Rice's Mayfair Witches", poster: "/p.jpg")])
        #expect(entries.count == 1)
        #expect(entries[0].title == "Anne Rice's Mayfair Witches", "the library's title over the release name")
        #expect(entries[0].code == "S01E01–E08, S02E01–E08")
        #expect(entries[0].count == 16)
        #expect(entries[0].event == .arrived)
    }

    @Test func episodesWithGapsAreListed() {
        let entries = activity([
            event(.imported, "sonarr", "Show.S01E01.1080p", "2026-10-11T08:00:00Z", series: 1),
            event(.imported, "sonarr", "Show.S01E02.1080p", "2026-10-11T08:01:00Z", series: 1),
            event(.imported, "sonarr", "Show.S01E04.1080p", "2026-10-11T08:05:00Z", series: 1),
        ])
        #expect(entries[0].code == "S01E01–E02, E04", "numbers from the release names when the server sends none")
        #expect(entries[0].count == 3)
    }

    @Test func aDifferentDayIsADifferentEntry() {
        let entries = activity([
            event(.imported, "sonarr", "Show.S01E01.1080p", "2026-10-10T08:00:00Z", series: 1),
            event(.imported, "sonarr", "Show.S01E02.1080p", "2026-10-11T08:00:00Z", series: 1),
        ])
        #expect(entries.map(\.code) == ["S01E02", "S01E01"], "newest first")
    }

    @Test func theLatestEventOfTheDaySaysWhereItGotTo() {
        let entries = activity([
            event(.imported, "sonarr", "Show.S01E01.1080p", "2026-10-11T08:00:00Z", series: 1),
            event(.failed, "sonarr", "Show.S01E02.1080p", "2026-10-11T09:00:00Z", series: 1),
        ])
        #expect(entries.count == 1)
        #expect(entries[0].event == .failed)
        #expect(entries[0].code == "S01E02", "the episodes it happened to")
    }

    @Test func aGrabNotYetImportedIsAGrab() {
        let entries = activity([event(.fetched, "radarr", "Dune.Part.Two.2024.2160p", "2026-10-11T11:00:00Z", movie: 3)])
        #expect(entries[0].event == .grabbed)
    }

    @Test func torrentsFinishingAndIncompleteStepsAreNotActivity() {
        let entries = activity([
            event(.completed, "qbittorrent", "Some.Torrent", "2026-10-11T10:00:00Z"),
            event(.incomplete, "readarr", "William.Gibson.Count.Zero", "2026-09-22T20:17:18Z", book: 135),
            event(.imported, "readarr", "William.Gibson.Count.Zero", "2026-09-23T13:28:34Z", book: 135),
        ])
        #expect(entries.count == 1)
        #expect(entries[0].kind == .book)
        #expect(entries[0].event == .arrived)
    }

    @Test func aPosterCountsOnlyOnceItsFileIsThere() {
        let entries = activity([
            event(.imported, "radarr", "A.2026.1080p", "2026-10-11T10:00:00Z", movie: 1),
            event(.imported, "radarr", "B.2026.1080p", "2026-10-11T09:00:00Z", movie: 2),
        ], posters: ["movie-2"])
        #expect(entries.map(\.hasPoster) == [false, true])
    }

    @Test func theNewestEightAcrossEveryArr() {
        let films = (0..<6).map { (n: Int) in event(.imported, "radarr", "Film\(n).2026.1080p", "2026-10-11T0\(n):00:00Z", movie: n) }
        let books = (0..<6).map { (n: Int) in event(.imported, "readarr", "Book\(n)", "2026-10-10T0\(n):00:00Z", book: n) }
        let entries = activity(films + books)
        #expect(entries.count == GlanceSnapshot.Activity.shown)
        #expect(entries.first?.title == "Film5")
        #expect(entries.prefix(6).allSatisfy { $0.kind == .movie })
    }

    @Test func nothingAtAllIsAnEmptyList() {
        #expect(activity([]).isEmpty)
    }
}
