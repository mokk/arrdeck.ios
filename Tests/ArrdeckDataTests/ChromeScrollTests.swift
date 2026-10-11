import Foundation
import Testing
@testable import ArrdeckData

struct ChromeScrollTests {
    /// A tall page, scrolled through `offsets` in small steps as a finger would.
    func scroll(_ chrome: inout ChromeScroll, _ offsets: [Double], height: Double = 5000) {
        for offset in offsets {
            chrome.scrolled(to: .init(offset: offset, maxOffset: height - 800, contentHeight: height))
        }
    }

    func steps(from start: Double, to end: Double, by step: Double = 5) -> [Double] {
        Array(stride(from: start, through: end, by: start < end ? step : -step))
    }

    @Test func scrollingDownFoldsItAway() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 80))
        #expect(chrome.expanded, "still near the top")
        scroll(&chrome, steps(from: 80, to: 115))
        #expect(!chrome.expanded)
    }

    @Test func aSmallScrollUpDoesNotBringItBack() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        scroll(&chrome, steps(from: 1000, to: 920))
        #expect(!chrome.expanded, "back past something, 80pt")
        scroll(&chrome, steps(from: 920, to: 895))
        #expect(chrome.expanded, "a deliberate 105pt up")
    }

    @Test func goingDownAgainStartsTheCountOver() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        scroll(&chrome, steps(from: 1000, to: 940))
        scroll(&chrome, steps(from: 940, to: 980))
        scroll(&chrome, steps(from: 980, to: 920))
        #expect(!chrome.expanded, "two 60pt scrolls up are not one of 120")
    }

    @Test func jitterAgainstTheDirectionKeepsTheCount() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        scroll(&chrome, steps(from: 1000, to: 940) + [945] + steps(from: 945, to: 895))
        #expect(chrome.expanded, "a 5pt wobble keeps the 60pt already travelled")
    }

    @Test func nearTheTopItIsAlwaysOut() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 300))
        scroll(&chrome, steps(from: 300, to: 220, by: 2))
        #expect(!chrome.expanded)
        // a fast flick back to the top lands in big steps
        scroll(&chrome, [90, 40])
        #expect(chrome.expanded)
    }

    @Test func aShortPageNeverFolds() {
        var chrome = ChromeScroll()
        for offset in steps(from: 0, to: 50) {
            chrome.scrolled(to: .init(offset: offset, maxOffset: 50, contentHeight: 850))
        }
        #expect(chrome.expanded)
    }

    @Test func aJumpIsNotAScroll() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        // "Today" or the letter strip, far up in one step
        scroll(&chrome, [400])
        #expect(!chrome.expanded)
        scroll(&chrome, steps(from: 400, to: 330))
        #expect(!chrome.expanded, "the count starts after the jump")
    }

    @Test func contentChangingUnderneathIsNotAScroll() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        // "Show earlier" prepends 400pt and the offset moves with it
        scroll(&chrome, [1100], height: 5400)
        scroll(&chrome, [1080], height: 5400)
        #expect(!chrome.expanded)
    }

    @Test func rubberBandingPastTheBottomIsIgnored() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 4200))
        // the bounce: past the end and settling back
        scroll(&chrome, [4260, 4300, 4250, 4200])
        #expect(!chrome.expanded)
    }

    @Test func resetBringsItBack() {
        var chrome = ChromeScroll()
        scroll(&chrome, steps(from: 0, to: 1000))
        chrome.reset()
        #expect(chrome.expanded)
        // the next page's first sample is only a reference point
        scroll(&chrome, [2000, 2005])
        #expect(chrome.expanded)
    }
}
