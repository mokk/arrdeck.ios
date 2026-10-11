import Foundation
import Testing
@testable import ArrdeckData

struct ShellLayoutTests {
    @Test func onlyAWideIPadGetsTheSidebar() {
        #expect(ShellLayout(regularWidth: true, isPad: true) == .sidebar)
        #expect(ShellLayout(regularWidth: false, isPad: true) == .tabBar, "Slide Over and narrow Split View look like the phone")
        #expect(ShellLayout(regularWidth: true, isPad: false) == .tabBar, "a Max iPhone in landscape keeps its capsule")
        #expect(ShellLayout(regularWidth: false, isPad: false) == .tabBar)
    }

    @Test func tappingAnotherTabShowsIt() {
        #expect(TabTap(.shows, selected: .movies, pushed: []) == .show(.shows))
        // whatever is pushed in it stays: switching never pops
        #expect(TabTap(.shows, selected: .movies, pushed: [.shows, .movies]) == .show(.shows))
    }

    @Test func tappingTheCurrentTabReturnsItToItsFirstScreen() {
        #expect(TabTap(.movies, selected: .movies, pushed: [.movies]) == .popToRoot(.movies))
        #expect(TabTap(.movies, selected: .movies, pushed: [.shows]) == .nothing, "already on its first screen")
    }

    @Test func theSelectionSurvivesWhileItsTabDoes() {
        #expect(AppTab.keeping(.shows, in: [.movies, .shows, .settings]) == .shows)
        #expect(AppTab.keeping(.books, in: [.movies, .shows, .settings]) == .movies, "Readarr went away")
        #expect(AppTab.keeping(.books, in: []) == .settings)
    }
}
