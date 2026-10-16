import XCTest

/// The chrome without a navigation bar: the tab bar folds into one icon as a
/// page scrolls down and comes back after a deliberate scroll up, the page's
/// actions float at the bottom right, and a pushed page goes back by its
/// floating button or a swipe from the edge. Opt-in like OnboardingUITests:
/// needs TEST_RUNNER_ARRDECK_CONNECTIONS.
@MainActor
final class ChromeUITests: XCTestCase {
    func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("chrome-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func openMovies() throws -> XCUIApplication {
        let app = XCUIApplication()
        try launchWithServices(app)
        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 15), "tab bar never appeared")
        any["tab-movies"].tap()
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no movie cards rendered")
        return app
    }

    func openFirstMovie() throws -> XCUIApplication {
        let app = try openMovies()
        let any = app.descendants(matching: .any)
        any.matching(identifier: "library-card").element(boundBy: 1).tap()
        XCTAssert(any["movie-detail"].waitForExistence(timeout: 10), "card did not open the detail")
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "detail never loaded its actions")
        sleep(1)
        return app
    }

    /// A slow drag of `points` up (positive) or down the middle of the screen,
    /// slow enough not to fling.
    func drag(_ app: XCUIApplication, up points: CGFloat) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: points > 0 ? 0.7 : 0.3))
        let end = start.withOffset(CGVector(dx: 0, dy: -points))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(height / 3), thenHoldForDuration: 0.3)
    }

    func testAPushedPageHasNoBarAndGoesBack() throws {
        let app = try openFirstMovie()
        let any = app.descendants(matching: .any)
        snap("movie-top")
        // the other tabs keep theirs in the hierarchy, hidden; the film's title is not among them
        XCTAssertFalse(app.showsNavigationBar, "the title page still has a navigation bar")
        XCTAssert(app.buttons["chrome-back"].exists, "no floating back button")

        // from the edge, as a thumb does
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.55)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssert(any["movie-detail"].waitForNonExistence(timeout: 5), "an edge swipe did not go back from a title")

        any.matching(identifier: "library-card").element(boundBy: 1).tap()
        XCTAssert(app.buttons["chrome-back"].waitForExistence(timeout: 10))
        XCTAssert(app.buttons["chrome-back"].isHittable, "the back button is under the tab bar")
        app.buttons["chrome-back"].tap()
        XCTAssert(any["movie-detail"].waitForNonExistence(timeout: 5), "the back button did not go back")
    }

    func testScrollingFoldsTheChromeAndADeliberateScrollUpUnfoldsIt() throws {
        let app = try openFirstMovie()
        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-movies"].exists)

        drag(app, up: 300)
        XCTAssert(any["tab-folded"].waitForExistence(timeout: 3), "scrolling down did not fold the tab bar")
        XCTAssertFalse(any["tab-movies"].exists)
        XCTAssertFalse(app.buttons["chrome-back"].exists, "the back button stayed out")
        snap("movie-folded")

        drag(app, up: -50)
        sleep(1)
        XCTAssert(any["tab-folded"].exists, "a small scroll up unfolded it")

        drag(app, up: -160)
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 3), "a deliberate scroll up did not unfold it")
        XCTAssert(app.buttons["chrome-back"].exists, "the back button did not come back")

        // folded again, the circle unfolds it without leaving the page
        drag(app, up: 300)
        XCTAssert(any["tab-folded"].waitForExistence(timeout: 3), "it did not fold a second time")
        any["tab-folded"].tap()
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 3), "tapping the folded icon did not unfold it")
        XCTAssert(any["movie-detail"].exists, "tapping the folded icon left the page")
    }

    func testTheLibraryHasItsActionsAndSearchAtTheBottom() throws {
        let app = try openMovies()
        let any = app.descendants(matching: .any)
        snap("library-top")
        XCTAssertFalse(app.showsNavigationBar, "the library still has a navigation bar")
        XCTAssertNil(app.visibleHeading, "the library has a heading; the tab bar says where you are")
        // every library tab has these; the hidden ones stay in the hierarchy
        func visible(_ id: String) -> XCUIElement? {
            any.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
        }
        for id in ["library-search", "library-sort", "library-add"] {
            XCTAssertNotNil(visible(id), "\(id) is not in reach")
        }

        drag(app, up: 400)
        XCTAssert(any["tab-folded"].waitForExistence(timeout: 3), "scrolling the library did not fold the tab bar")
        XCTAssertNil(visible("library-add"), "the actions stayed out")
        drag(app, up: -200)
        sleep(1)
        XCTAssertNotNil(visible("library-add"), "the actions did not come back")

        let noMatches = app.staticTexts["No matches"]
        try XCTUnwrap(visible("library-search")).tap()
        let field = app.textFields["chrome-search-field"]
        XCTAssert(field.waitForExistence(timeout: 3), "the search field did not open")
        XCTAssertFalse(any["tab-movies"].isHittable, "the tab bar stayed over the keyboard")
        field.typeText("zzqx")
        sleep(1)
        snap("library-searching")
        XCTAssert(noMatches.exists, "typing did not filter the library")
        app.buttons["chrome-search-close"].tap()
        XCTAssert(field.waitForNonExistence(timeout: 3), "closing did not close the field")
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 3))
        XCTAssertFalse(noMatches.exists, "closing did not clear the search")
    }

    /// Screenshots each tab at its top and scrolled, and a page pushed from a
    /// few of them, for comparing by eye. Asserts only that each tab has no
    /// navigation bar and a heading.
    func testTourTheTabs() throws {
        let app = try openMovies()
        let any = app.descendants(matching: .any)
        for tab in ["books", "music", "movies", "shows", "activity", "calendar", "settings"] where any["tab-\(tab)"].exists {
            if any["tab-folded"].exists { any["tab-folded"].tap() }
            any["tab-\(tab)"].tap()
            sleep(3)
            snap("tour-\(tab)")
            XCTAssertFalse(app.showsNavigationBar, "\(tab) still shows a navigation bar")
            drag(app, up: 350)
            sleep(1)
            snap("tour-\(tab)-scrolled")
            drag(app, up: -250)
            sleep(1)
        }
        if any["tab-folded"].exists { any["tab-folded"].tap() }
        any["tab-shows"].tap()
        sleep(1)
        let card = any.matching(identifier: "library-card").allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(card).tap()
        sleep(4)
        snap("tour-show-detail")
        any["tab-activity"].tap()
        for segment in ["Downloading", "Queue"] where app.buttons[segment].exists {
            app.buttons[segment].tap()
            sleep(2)
            snap("tour-activity-\(segment.lowercased())")
        }
    }

    /// Swiping right on a row of posters scrolled along scrolls it back; it
    /// does not take the swipe as "back", now that the page's swipe-anywhere
    /// back is ours to allow.
    func testSwipingAPosterRowScrollsItInsteadOfGoingBack() throws {
        let app = try openFirstMovie()
        let any = app.descendants(matching: .any)
        let row = any["credits-row"].firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { drag(app, up: 250) }
        guard row.exists, row.isHittable else { throw XCTSkip("this film has no cast row") }
        row.swipeLeft()
        sleep(1)
        let middle = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 120, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
        snap("credits-after-right-swipe")
        XCTAssert(any["movie-detail"].exists, "a right swipe on the cast row went back instead of scrolling it")
    }
}
