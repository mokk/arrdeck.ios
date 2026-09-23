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
        let outcome = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'no sign-in needed'")
        ).firstMatch
        XCTAssert(outcome.waitForExistence(timeout: 15), "probe never reported reachable")

        app.buttons["save-server"].tap()

        // Back on the list, the saved profile shows its version line, which
        // only exists when the probe's BackendInfo was carried into the store.
        let row = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'arrdeck '")
        ).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5), "saved profile lost its capabilities")

        // Into the server: the dashboard, fed by the generated client through
        // the same session, with a card that only renders once /services and
        // /diskspace have both answered.
        row.tap()
        let dashboard = app.descendants(matching: .any)["dashboard"].firstMatch
        XCTAssert(dashboard.waitForExistence(timeout: 10), "dashboard never appeared")
        XCTAssertFalse(app.descendants(matching: .any)["connection-error"].exists, "dashboard reported a connection error")
        // The list is lazy: a section below the fold is not in the
        // accessibility tree until scrolled into view.
        let storage = app.staticTexts["Storage"]
        for _ in 0..<8 where !storage.exists {
            app.swipeUp()
        }
        XCTAssert(storage.waitForExistence(timeout: 15), "storage card never rendered")
        snap("dashboard-lower")

        // History and Statistics from their cards' header links, further down.
        for (link, screen, marker, shot) in [
            ("history-link", "history", "Blocklist", "history"),
            ("stats-link", "stats", "Library size", "stats"),
        ] {
            let button = app.buttons[link]
            for _ in 0..<8 where !button.exists { app.swipeUp() }
            XCTAssert(button.waitForExistence(timeout: 5), "no \(link) on the dashboard")
            button.tap()
            XCTAssert(app.descendants(matching: .any)[screen].firstMatch.waitForExistence(timeout: 10), "\(screen) never appeared")
            // Segmented-control labels are buttons, section titles are static
            // texts; match either.
            XCTAssert(app.descendants(matching: .any)[marker].firstMatch.waitForExistence(timeout: 20), "\(screen) never loaded")
            snap(shot)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Into the calendar from the Upcoming card's header link.
        let calendarLink = app.buttons["calendar-link"]
        for _ in 0..<4 where !calendarLink.exists {
            app.swipeDown()
        }
        XCTAssert(calendarLink.waitForExistence(timeout: 5), "no calendar link on the dashboard")
        calendarLink.tap()
        let calendarScreen = app.descendants(matching: .any)["calendar"].firstMatch
        XCTAssert(calendarScreen.waitForExistence(timeout: 10), "calendar never appeared")
        XCTAssert(app.buttons["Agenda"].waitForExistence(timeout: 5), "calendar view picker missing")
        snap("calendar")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Into Downloads: the merged torrent list from /torrents, through the
        // same client. The header counts rows once the first page has landed.
        app.tabBars.buttons["Downloads"].tap()
        let downloads = app.descendants(matching: .any)["downloads"].firstMatch
        XCTAssert(downloads.waitForExistence(timeout: 10), "downloads screen never appeared")
        let counted = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[1-9][0-9]* of [0-9]+ torrents'")
        ).firstMatch
        XCTAssert(counted.waitForExistence(timeout: 20), "torrent list never loaded")
        XCTAssert(app.descendants(matching: .any)["torrent-row"].firstMatch.exists, "no torrent rows rendered")
        snap("downloads")

        // Select mode: the bulk bar appears with nothing selected, a tapped
        // row counts, Done leaves the mode.
        app.buttons["select"].tap()
        XCTAssert(app.staticTexts["0 selected"].waitForExistence(timeout: 5), "bulk bar never appeared")
        app.descendants(matching: .any)["torrent-row"].firstMatch.tap()
        XCTAssert(app.staticTexts["1 selected"].waitForExistence(timeout: 5), "tapping a row did not select it")
        snap("downloads-select")
        app.buttons["select"].tap()
        XCTAssertFalse(app.staticTexts["1 selected"].exists, "Done did not leave select mode")

        // The add-torrent sheet opens and cancels.
        app.buttons["add-torrent"].tap()
        XCTAssert(app.staticTexts["Add torrent"].waitForExistence(timeout: 5), "add-torrent sheet never appeared")
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["Home"].tap()

        // Into a title: the first recently-added poster opens its detail
        // screen, movie or series depending on which arr it came from.
        let poster = app.descendants(matching: .any)["recent-poster"].firstMatch
        for _ in 0..<8 where !poster.exists {
            app.swipeDown()   // back to the top: the strip sits above the fold
        }
        XCTAssert(poster.waitForExistence(timeout: 10), "no recently-added poster to tap")
        poster.tap()
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'movie-detail', 'series-detail'}")
        ).firstMatch
        XCTAssert(detail.waitForExistence(timeout: 10), "detail screen never appeared")
        XCTAssert(app.buttons["Search now"].waitForExistence(timeout: 15), "detail never loaded its actions")
        snap("detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Into Wanted: the missing list for the first arr, with its count.
        app.buttons["wanted-link"].tap()
        let wanted = app.descendants(matching: .any)["wanted"].firstMatch
        XCTAssert(wanted.waitForExistence(timeout: 10), "wanted screen never appeared")
        let wantedCount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]+ items'")
        ).firstMatch
        XCTAssert(wantedCount.waitForExistence(timeout: 20), "wanted list never loaded")
        snap("wanted")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Manage: the hub, then the connection settings it links to — the one
        // screen that reads every service's saved configuration.
        app.tabBars.buttons["Manage"].tap()
        let manage = app.descendants(matching: .any)["manage"].firstMatch
        XCTAssert(manage.waitForExistence(timeout: 10), "manage hub never appeared")
        snap("manage")
        app.buttons["manage-system"].tap()
        XCTAssert(app.staticTexts["Scheduled tasks"].waitForExistence(timeout: 20), "system screen never loaded")
        snap("system")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["manage-connections"].tap()
        XCTAssert(app.staticTexts["configured"].firstMatch.waitForExistence(timeout: 20), "connections never loaded")
        snap("connections")

        // Add: Overseerr's popular titles fill the grid while the box is empty.
        app.tabBars.buttons["Add"].tap()
        XCTAssert(app.descendants(matching: .any)["add"].firstMatch.waitForExistence(timeout: 10), "add screen never appeared")
        XCTAssert(app.descendants(matching: .any)["search-result"].firstMatch.waitForExistence(timeout: 30), "no popular titles rendered")
        snap("add")

        // Popular: the cached snapshot, or the honest "building" note if the
        // backend has not produced one yet.
        app.tabBars.buttons["Popular"].tap()
        XCTAssert(app.descendants(matching: .any)["popular"].firstMatch.waitForExistence(timeout: 10), "popular screen never appeared")
        let popularLoaded = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'releases in' OR label CONTAINS 'Building the first list' OR label CONTAINS 'Offline'")
        ).firstMatch
        XCTAssert(popularLoaded.waitForExistence(timeout: 30), "popular never rendered")
        snap("popular")
        app.tabBars.buttons["Home"].tap()

        // Relaunch: the profile must come back from the Keychain, not from
        // memory — and being the only one, it opens straight to its dashboard.
        // The first version of this test asserted only in-memory state and
        // passed while every Keychain call was failing (unsigned build).
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssert(dashboard.waitForExistence(timeout: 10), "profile did not survive a relaunch")
        XCTAssertFalse(
            app.staticTexts["Could not read saved servers"].exists,
            "keychain read failed after relaunch"
        )
    }
}
