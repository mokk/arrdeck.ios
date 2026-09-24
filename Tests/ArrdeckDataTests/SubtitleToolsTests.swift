import Foundation
import ArrdeckData
import Testing

@Suite struct ProfilePicksTests {
    let titles: [SubtitleTitle] = [
        .init(id: 1, kind: .series, profile_id: nil, title: "Slow Horses"),
        .init(id: 2, kind: .series, profile_id: 1, title: "The Bear"),
        .init(id: 3, kind: .movie, profile_id: nil, title: "Heat"),
    ]

    @Test func showsOnlyTheKindAndTheUnsetByDefault() {
        var picks = ProfilePicks()
        #expect(picks.shown(titles).map(\.id) == [1])
        #expect(picks.unsetCount(titles) == 1)
        picks.onlyUnset = false
        #expect(picks.shown(titles).map(\.id) == [1, 2])
        picks.show(movies: true)
        #expect(picks.shown(titles).map(\.id) == [3])
    }

    @Test func selectAllTogglesWhatIsShownAndSwitchingKindStartsOver() {
        var picks = ProfilePicks()
        picks.onlyUnset = false
        picks.toggleAll(titles)
        #expect(picks.picked == [1, 2])
        #expect(picks.allPicked(titles))
        picks.toggleAll(titles)
        #expect(picks.picked.isEmpty)
        picks.toggle(2)
        picks.show(movies: true)
        #expect(picks.picked.isEmpty)
    }
}

@Suite struct IcalSettingsTests {
    let base = URL(string: "http://10.0.0.154:3500")!

    @Test func addressIsNilWhileOffAndNarrowsToTheChosenApps() {
        let off = IcalSettings(apps: ["radarr", "sonarr"], enabled: false, token: nil)
        #expect(off.url(on: base) == nil)
        let on = IcalSettings(apps: ["radarr", "sonarr", "readarr"], enabled: true, token: "T")
        #expect(on.url(on: base)?.absoluteString == "http://10.0.0.154:3500/ical/T/arrdeck.ics")
        #expect(on.url(on: base, apps: ["radarr", "sonarr", "readarr"])?.query == nil)
        #expect(on.url(on: base, apps: ["sonarr", "radarr"])?.query == "apps=radarr,sonarr")
        #expect(on.webcal(on: base)?.absoluteString == "webcal://10.0.0.154:3500/ical/T/arrdeck.ics")
    }
}
