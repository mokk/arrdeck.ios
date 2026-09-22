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

        // Into Downloads: the merged torrent list from /torrents, through the
        // same client. The header counts rows once the first page has landed.
        app.buttons["downloads-link"].tap()
        let downloads = app.descendants(matching: .any)["downloads"].firstMatch
        XCTAssert(downloads.waitForExistence(timeout: 10), "downloads screen never appeared")
        let counted = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[1-9][0-9]* of [0-9]+ torrents'")
        ).firstMatch
        XCTAssert(counted.waitForExistence(timeout: 20), "torrent list never loaded")
        XCTAssert(app.descendants(matching: .any)["torrent-row"].firstMatch.exists, "no torrent rows rendered")
        snap("downloads")
        app.navigationBars.buttons.element(boundBy: 0).tap()

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
