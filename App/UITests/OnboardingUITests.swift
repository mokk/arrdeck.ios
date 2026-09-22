import XCTest

/// Drives the real app in the simulator against a real backend — the only
/// place the ATS exception, the local-network permission and the probe meet
/// the actual iOS network stack. Opt-in: pass the backend as
/// TEST_RUNNER_ARRDECK_LIVE_URL to xcodebuild (the TEST_RUNNER_ prefix is how
/// env vars reach the test runner process); skipped when absent, so CI passes
/// without a backend.
final class OnboardingUITests: XCTestCase {
    func testAddingTheLANServerEndToEnd() throws {
        guard let live = ProcessInfo.processInfo.environment["ARRDECK_LIVE_URL"] else {
            throw XCTSkip("set TEST_RUNNER_ARRDECK_LIVE_URL to run against a real backend")
        }

        let app = XCUIApplication()
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

        // Relaunch: the row must come back from the Keychain, not from memory.
        // The first version of this test asserted only in-memory state and
        // passed while every Keychain call was failing (unsigned build).
        app.terminate()
        app.launch()
        XCTAssert(row.waitForExistence(timeout: 5), "profile did not survive a relaunch")
        XCTAssertFalse(
            app.staticTexts["Could not read saved servers"].exists,
            "keychain read failed after relaunch"
        )
    }
}
