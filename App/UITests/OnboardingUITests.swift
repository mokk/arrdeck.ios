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
        XCTAssertFalse(any["tab-books"].exists, "Books must stay hidden without Readarr")
        // A ScrollView's identifier is not exposed under .searchable; the title is.
        XCTAssert(app.navigationBars["Movies"].waitForExistence(timeout: 10), "movies page never appeared")
        XCTAssert(any["library-card"].firstMatch.waitForExistence(timeout: 20), "no movie cards rendered")
        snap("movies")
        any["library-card"].firstMatch.tap()
        XCTAssert(any["movie-detail"].waitForExistence(timeout: 10), "card did not open the detail")
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "detail never loaded its actions")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The add sheet, scoped to movies: Overseerr's popular titles fill it.
        app.buttons["library-add"].tap()
        XCTAssert(app.staticTexts["Add movie"].waitForExistence(timeout: 5), "add sheet never appeared")
        XCTAssert(any["search-result"].firstMatch.waitForExistence(timeout: 30), "no popular titles rendered")
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
        XCTAssert(app.staticTexts["Torrents"].waitForExistence(timeout: 20), "downloading segment never loaded")
        snap("activity")
        app.buttons["Queue"].tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label MATCHES '[1-9][0-9]* of [0-9]+ torrents'")).firstMatch.waitForExistence(timeout: 20), "queue never loaded")
        app.buttons["History"].tap()
        XCTAssert(app.buttons["Blocklist"].waitForExistence(timeout: 10), "history never appeared")

        // Calendar.
        any["tab-calendar"].tap()
        XCTAssert(any["calendar"].waitForExistence(timeout: 10), "calendar never appeared")
        XCTAssert(app.buttons["Agenda"].waitForExistence(timeout: 5), "calendar view picker missing")

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
        app.buttons["manage-connections"].tap()
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
