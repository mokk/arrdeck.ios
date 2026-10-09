import XCTest

/// Visits every tab and every Settings page and screenshots each, so the
/// screens can be compared side by side — headings, segment pickers, toolbars.
/// Asserts nothing about data: it runs against any backend, even one whose
/// services are all offline. Opt-in like OnboardingUITests: needs
/// TEST_RUNNER_ARRDECK_LIVE_URL and TEST_RUNNER_ARRDECK_SCREENSHOT_DIR.
@MainActor
final class ScreenTourUITests: XCTestCase {
    func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("tour-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func testTourEveryScreen() throws {
        guard let live = ProcessInfo.processInfo.environment["ARRDECK_LIVE_URL"],
              ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] != nil
        else { throw XCTSkip("set TEST_RUNNER_ARRDECK_LIVE_URL and TEST_RUNNER_ARRDECK_SCREENSHOT_DIR") }

        let app = XCUIApplication()
        // English whatever the simulator's language, so rows are found by label
        app.launchArguments = ["--reset-profiles", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "permission") { alert in
            for label in ["Allow", "Tillad", "Don’t Allow"] where alert.buttons[label].exists {
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
        XCTAssert(app.buttons["save-server"].waitForExistence(timeout: 15))
        app.buttons["save-server"].tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'arrdeck '")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 5))
        row.tap()

        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-settings"].waitForExistence(timeout: 15), "tab bar never appeared")
        app.tap()

        for tab in ["books", "movies", "shows", "activity", "calendar", "settings"] where any["tab-\(tab)"].exists {
            any["tab-\(tab)"].tap()
            sleep(2)
            snap("tab-\(tab)")
            if tab == "activity" {
                for segment in ["Downloading", "Queue", "History"] where app.buttons[segment].exists {
                    app.buttons[segment].tap()
                    sleep(2)
                    snap("activity-\(segment.lowercased())")
                }
            }
        }

        // Every Settings page reachable from the hub, by its row's label.
        let pages = [
            "Display", "Popular releases", "Statistics", "Overview", "Cleanup", "Wanted", "Indexers",
            "System", "Subtitles", "Connections", "Calendar subscription", "Exclusions", "Release name tester",
            "Reading apps", "Notifications",
        ]
        for page in pages {
            any["tab-settings"].tap()
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
            for _ in 0..<4 where !link.isHittable { app.swipeUp() }
            guard link.exists, link.isHittable else { continue }
            link.tap()
            sleep(2)
            snap("settings-\(page.lowercased().replacingOccurrences(of: " ", with: "-"))")
            // and straight back by re-tapping the tab
            any["tab-settings"].tap()
            XCTAssert(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                      "re-tapping Settings did not return from \(page)")
            for _ in 0..<4 { app.swipeDown() }
        }
        snap("settings-after-tour")
    }
}
