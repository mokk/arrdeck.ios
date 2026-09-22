import ArrdeckData
import Foundation
import Testing

@Suite struct FormatTests {
    let en = Locale(identifier: "en_US")
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }
    // 2026-09-22 12:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_790_078_400)

    @Test func bytesMatchThePWA() {
        #expect(Format.bytes(nil, locale: en) == "0 B")
        #expect(Format.bytes(0, locale: en) == "0 B")
        #expect(Format.bytes(512, locale: en) == "512 B")
        #expect(Format.bytes(1536, locale: en) == "1.5 KB")
        #expect(Format.bytes(2_658_872_609_091, locale: en) == "2.4 TB")
        #expect(Format.speed(110_792, locale: en) == "108.2 KB/s")
    }

    @Test func parsesTheArrsDateShapes() {
        #expect(Format.parseDate("2026-09-18T17:31:09Z") == Date(timeIntervalSince1970: 1_789_752_669))
        #expect(Format.parseDate("2026-09-18T17:31:09.123Z") != nil)
        #expect(Format.parseDate("2026-09-18", timeZone: TimeZone(identifier: "UTC")!)
            == Date(timeIntervalSince1970: 1_789_689_600))
        #expect(Format.parseDate("not a date") == nil)
    }

    @Test func namesTodayAndTomorrow() {
        #expect(Format.day("2026-09-22T18:00:00Z", now: now, calendar: utc, locale: en) == "Today")
        #expect(Format.day("2026-09-23T04:00:00Z", now: now, calendar: utc, locale: en) == "Tomorrow")
        #expect(Format.day("2026-09-29T00:00:00Z", now: now, calendar: utc, locale: en) == "Sep 29")
        #expect(Format.day(nil, now: now, calendar: utc, locale: en) == "—")
    }

    /// Foundation puts a narrow no-break space (U+202F) before the meridiem;
    /// the expectations spell it out so a failure here is a real one.
    @Test func dayTimeKeepsTheCommaAlignment() {
        #expect(Format.dayTime("2026-09-22T13:38:00Z", now: now, calendar: utc, locale: en) == "Today, 1:38\u{202F}PM")
        #expect(Format.dayTime("2026-09-18T17:31:09Z", now: now, calendar: utc, locale: en) == "Sep 18, 5:31\u{202F}PM")
    }

    @Test func danishGetsItsOwnWords() {
        let da = Locale(identifier: "da_DK")
        #expect(Format.day("2026-09-22T18:00:00Z", now: now, calendar: utc, locale: da) == "I dag")
        #expect(Format.bytes(1536, locale: da) == "1,5 KB")
    }
}
