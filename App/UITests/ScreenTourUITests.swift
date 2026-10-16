import XCTest

/// Visits every tab and every Settings page and screenshots each, so the
/// screens can be compared side by side — headings, segment pickers, toolbars.
/// Asserts nothing about data: it runs against any services, even ones that
/// are all offline. Opt-in like OnboardingUITests: needs
/// TEST_RUNNER_ARRDECK_CONNECTIONS and TEST_RUNNER_ARRDECK_SCREENSHOT_DIR.
@MainActor
final class ScreenTourUITests: XCTestCase {
    func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("tour-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func testTourEveryScreen() throws {
        guard ProcessInfo.processInfo.environment["ARRDECK_SCREENSHOT_DIR"] != nil
        else { throw XCTSkip("set TEST_RUNNER_ARRDECK_SCREENSHOT_DIR") }

        let app = XCUIApplication()
        // English whatever the simulator's language, so rows are found by label
        try launchWithServices(app)

        let any = app.descendants(matching: .any)
        XCTAssert(any["tab-settings"].waitForExistence(timeout: 15), "tab bar never appeared")
        app.tap()

        for tab in ["books", "music", "movies", "shows", "activity", "calendar", "settings"] where app.tab(tab).exists {
            app.tab(tab).tap()
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
            "System", "Subtitles", "Connections", "Exclusions", "Release name tester",
        ]
        for page in pages {
            app.tab("settings").tap()
            let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
            for _ in 0..<4 where !link.isHittable { app.swipeUp() }
            guard link.exists, link.isHittable else { continue }
            link.tap()
            sleep(2)
            snap("settings-\(page.lowercased().replacingOccurrences(of: " ", with: "-"))")
            XCTAssertFalse(app.showsNavigationBar, "\(page) still has a navigation bar")
            // and straight back by re-tapping the tab (unfolded first: the
            // folded icon only unfolds)
            app.tab("settings").tap()
            XCTAssert(app.waitForPage("settings", timeout: 5),
                      "re-tapping Settings did not return from \(page)")
            for _ in 0..<4 { app.swipeDown() }
        }
        snap("settings-after-tour")
    }
}
