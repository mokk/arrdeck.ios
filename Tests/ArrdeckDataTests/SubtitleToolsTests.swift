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
