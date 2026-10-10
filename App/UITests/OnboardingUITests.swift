import XCTest

/// Drives the real app in the simulator against a real backend — the only
/// place the ATS exception, the local-network permission and the probe meet
/// the actual iOS network stack. Opt-in: pass the backend as
/// TEST_RUNNER_ARRDECK_LIVE_URL to xcodebuild (the TEST_RUNNER_ prefix is how
/// env vars reach the test runner process); skipped when absent, so CI passes
/// without a backend.
final class OnboardingUITests: XCTestCase {
    /// With TEST_RUNNER_ARRDECK_SCREENSHOT_DIR set, drops a PNG of the current
    /// screen there — the simulator has no other way to reach a screen that
    /// takes several taps to get to.
    func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    /// Opens Movies on the live backend, the way the end-to-end test does.
    func openMovies(_ app: XCUIApplication, live: String) {
        app.launchArguments = ["--reset-profiles"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "local network") { alert in
            for label in ["Allow", "Tillad"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.buttons["add-server"].tap()
        let field = app.textFields["server-address"]
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(live.replacingOccurrences(of: "http://", with: ""))
        app.buttons["connect"].tap()
        app.tap()
        let outcome = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no sign-in needed'")).firstMatch
        XCTAssert(outcome.waitForExistence(timeout: 15), "probe never reported reachable")
        app.buttons["save-server"].tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'arrdeck '")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()
        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 15), "tab bar never appeared")
        any["tab-movies"].tap()
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no movie cards rendered")
    }

    /// iOS 26 goes back on a swipe from anywhere in the page, not only the
    /// edge; on a title page that swipe must not step to the previous title.
    func testSwipingRightGoesBack() throws {
        guard let live = ProcessInfo.processInfo.environment["ARRDECK_LIVE_URL"] else {
            throw XCTSkip("set TEST_RUNNER_ARRDECK_LIVE_URL to run against a real backend")
        }
        let app = XCUIApplication()
        openMovies(app, live: live)
        let any = app.descendants(matching: .any)
        let window = app.windows.firstMatch
        func swipeRight(from x: CGFloat) {
            // a quick flick, as a thumb does: a slow drag from mid-screen is
            // not taken as "back"
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.55)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        // the second film has a previous one to step to
        any.matching(identifier: "library-card").element(boundBy: 1).tap()
        XCTAssert(any["movie-detail"].waitForExistence(timeout: 10), "card did not open the detail")
        // swipe once the page has loaded: mid-load it re-lays out under the
        // finger, and iOS drops the swipe
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "detail never loaded its actions")
        sleep(1)
        let title = app.navigationBars.element(boundBy: 0).identifier
        swipeRight(from: 0.3)
        sleep(1)
        snap("title-after-mid-swipe")
        // Whether iOS takes a mid-screen flick as "back" depends on timing the
        // simulator does not keep steady; what must never happen is the old
        // bug, the swipe stepping to the previous title.
        if any["movie-detail"].exists {
            XCTAssertEqual(app.navigationBars.element(boundBy: 0).identifier, title,
                           "a right swipe stepped to another title instead of going back")
            swipeRight(from: 0.01)
        }
        XCTAssert(app.navigationBars["Movies"].waitForExistence(timeout: 5), "swiping right did not go back from a title")

        // from the edge on a Settings page (from mid-screen iOS only takes it
        // when the swipe doesn't start on a card of the list)
        any["tab-settings"].tap()
        app.buttons["manage-stats"].tap()
        XCTAssert(any["stats"].waitForExistence(timeout: 10))
        sleep(1)
        swipeRight(from: 0.01)
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "an edge swipe did not go back from Statistics")
    }

    func testAddingTheLANServerEndToEnd() throws {
        guard let live = ProcessInfo.processInfo.environment["ARRDECK_LIVE_URL"] else {
            throw XCTSkip("set TEST_RUNNER_ARRDECK_LIVE_URL to run against a real backend")
        }

        let app = XCUIApplication()
        // UI tests start from a clean slate; the simulator's Keychain outlives
        // an uninstall.
        app.launchArguments = ["--reset-profiles"]
        app.launch()

        // The local-network permission prompt can appear on first connect; iOS
        // only shows it once per install. Answer it if it does.
        addUIInterruptionMonitor(withDescription: "local network") { alert in
            for label in ["Allow", "Tillad"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.buttons["add-server"].tap()
        let field = app.textFields["server-address"]
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(live.replacingOccurrences(of: "http://", with: ""))
        app.buttons["connect"].tap()
        app.tap() // nudge, so a pending interruption monitor gets its chance

        // The probe's verdict on a LAN backend: reachable, no sign-in needed.
        let outcome = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no sign-in needed'")).firstMatch
        XCTAssert(outcome.waitForExistence(timeout: 15), "probe never reported reachable")
        app.buttons["save-server"].tap()

        // Back on the list, the saved profile shows its version line, which
        // only exists when the probe's BackendInfo was carried into the store.
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'arrdeck '")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5), "saved profile lost its capabilities")
        row.tap()

        // Movies: the tab bar appears once /services has answered, and the
        // library renders cards from /library/movies.
        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 15), "tab bar never appeared")
        // Readarr is configured on this backend, so Books is the first tab.
        XCTAssert(any["tab-books"].exists, "Books must appear when Readarr is configured")
        any["tab-books"].tap()
        XCTAssert(app.navigationBars["Books"].waitForExistence(timeout: 10), "books page never appeared")
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no book cards rendered")
        snap("books")
        any["library-card"].firstMatch.tap()
        XCTAssert(any["book-detail"].waitForExistence(timeout: 10), "card did not open the book")
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "book detail never loaded its actions")
        snap("book-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        any["tab-movies"].tap()
        // A ScrollView's identifier is not exposed under .searchable; the title is.
        XCTAssert(app.navigationBars["Movies"].waitForExistence(timeout: 10), "movies page never appeared")
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no movie cards rendered")
        snap("movies")
        // Back from landscape the grid must fit the portrait width again: it
        // once kept the landscape columns and ran off the right edge.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let screen = app.windows.firstMatch.frame
        let cards = any.matching(identifier: "library-card")
        XCTAssert(cards.firstMatch.waitForExistence(timeout: 10), "cards gone after rotating")
        for index in 0..<min(cards.count, 6) {
            let frame = cards.element(boundBy: index).frame
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.5, "card \(index) runs off the screen after rotating")
        }
        snap("movies-after-rotation")
        any["library-card"].firstMatch.tap()
        XCTAssert(any["movie-detail"].waitForExistence(timeout: 10), "card did not open the detail")
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "detail never loaded its actions")
        snap("movie-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The add sheet, scoped to movies: Overseerr's popular titles fill it.
        app.buttons["library-add"].tap()
        XCTAssert(app.staticTexts["Add movie"].waitForExistence(timeout: 5), "add sheet never appeared")
        // The watchlist, Trakt and recommendation rows come first, and a List
        // only builds the rows on screen: scroll down to the popular grid.
        let result = any["search-result"].firstMatch
        for _ in 0..<6 where !result.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssert(result.waitForExistence(timeout: 20), "no popular titles rendered")
        snap("add-movie")
        app.buttons["Cancel"].tap()

        // Shows.
        any["tab-shows"].tap()
        XCTAssert(app.navigationBars["Shows"].waitForExistence(timeout: 10), "shows page never appeared")
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no show cards rendered")
        snap("shows")

        // Activity: the arr queue and moving torrents, then the full queue.
        any["tab-activity"].tap()
        XCTAssert(any["activity"].waitForExistence(timeout: 10), "activity never appeared")
        // History opens first, with what is new since the last visit marked;
        // the torrents are under Downloading
        XCTAssert(app.buttons["Blocklist"].waitForExistence(timeout: 10), "history did not open first")
        snap("activity-history")
        app.buttons["Downloading"].tap()
        XCTAssert(app.staticTexts["Torrents"].waitForExistence(timeout: 20), "downloading segment never loaded")
        snap("activity")
        app.buttons["Queue"].tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label MATCHES '[1-9][0-9]* of [0-9]+ torrents'")).firstMatch.waitForExistence(timeout: 20), "queue never loaded")
        app.buttons["History"].tap()
        XCTAssert(app.buttons["Blocklist"].waitForExistence(timeout: 10), "history never came back")

        // Calendar.
        any["tab-calendar"].tap()
        XCTAssert(any["calendar"].waitForExistence(timeout: 10), "calendar never appeared")
        XCTAssert(app.buttons["Today"].waitForExistence(timeout: 5), "calendar has no way back to today")

        // Settings: the hub, the old dashboard as Overview, connections.
        any["tab-settings"].tap()
        XCTAssert(any["settings"].waitForExistence(timeout: 10), "settings never appeared")
        snap("settings")
        app.buttons["overview"].tap()
        XCTAssert(any["dashboard"].waitForExistence(timeout: 10), "overview never appeared")
        let storage = app.staticTexts["Storage"]
        for _ in 0..<8 where !storage.exists { app.swipeUp() }
        XCTAssert(storage.waitForExistence(timeout: 15), "storage card never rendered")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "did not return to Settings from Overview")
        snap("settings-after-overview")
        // Statistics → Watching, when Plex is set up: Plex's play history.
        app.buttons["manage-stats"].tap()
        XCTAssert(any["stats"].waitForExistence(timeout: 10), "statistics never appeared")
        if app.buttons["Watching"].exists {
            app.buttons["Watching"].tap()
            XCTAssert(app.staticTexts["Plays"].waitForExistence(timeout: 20)
                || app.staticTexts["Nothing watched in this period."].exists, "watch stats never loaded")
            snap("stats-watching")
            app.buttons["Library"].tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5), "did not return to Settings from Statistics")
        let connections = app.buttons["manage-connections"]
        // It is the last row. Under the tab bar it still counts as hittable, so
        // scroll to the bottom first rather than until it "can" be tapped.
        app.swipeUp()
        app.swipeUp()
        XCTAssert(connections.waitForExistence(timeout: 5), "connections row not reachable")
        // Subtitles, when Bazarr is set up: the missing list, then the profile editor.
        let subtitles = app.buttons["manage-subtitles"]
        if subtitles.exists {
            subtitles.tap()
            XCTAssert(app.buttons["Search all"].waitForExistence(timeout: 20)
                || app.staticTexts["Nothing is missing subtitles."].exists, "missing subtitles never loaded")
            snap("subtitles-missing")
            app.buttons["Language profiles"].tap()
            XCTAssert(app.buttons["Select all shown"].waitForExistence(timeout: 20), "profile editor never loaded")
            snap("subtitles-profiles")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.swipeUp()
        }
        connections.tap()
        XCTAssert(app.staticTexts["configured"].firstMatch.waitForExistence(timeout: 20), "connections never loaded")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Relaunch: the profile must come back from the Keychain, not from
        // memory — and being the only one, it opens straight to its tabs.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssert(any["tab-movies"].waitForExistence(timeout: 15), "profile did not survive a relaunch")
        XCTAssertFalse(app.staticTexts["Could not read saved servers"].exists, "keychain read failed after relaunch")
    }
}
