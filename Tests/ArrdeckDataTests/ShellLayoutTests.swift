import Foundation
import Testing
@testable import ArrdeckData

struct ShellLayoutTests {
    @Test func onlyARegularWindowGetsTheSidebar() {
        #expect(ShellLayout(regularWidth: true, regularHeight: true) == .sidebar, "a wide iPad or an unfolded iPhone Duo")
        #expect(ShellLayout(regularWidth: false, regularHeight: true) == .tabBar, "Slide Over, narrow Split View and a folded Duo look like the phone")
        #expect(ShellLayout(regularWidth: true, regularHeight: false) == .tabBar, "a Max iPhone in landscape keeps its capsule")
        #expect(ShellLayout(regularWidth: false, regularHeight: false) == .tabBar)
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
