import XCTest

/// Finding things on pages without a navigation bar. Every tab's stack stays
/// in the hierarchy, hidden, so a heading or a library's buttons can match in
/// several tabs at once; the one on screen is the hittable one.
extension XCUIApplication {
    /// The title of the detail page on screen, from its hero card. The tabs'
    /// own pages have none.
    var visibleHeading: String? {
        descendants(matching: .any).matching(identifier: "page-title")
            .allElementsBoundByIndex.first { $0.isHittable }?.label
    }

    /// Whether the page with this identifier is the one on screen ("settings",
    /// "library-radarr"), waiting up to `timeout`.
    func waitForPage(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if visible(identifier) != nil { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    /// Whether a navigation bar shows; the hidden tabs' stacks keep theirs in
    /// the hierarchy.
    var showsNavigationBar: Bool {
        navigationBars.allElementsBoundByIndex.contains { $0.isHittable }
    }

    /// The copy of this element on screen.
    func visible(_ identifier: String) -> XCUIElement? {
        descendants(matching: .any).matching(identifier: identifier)
            .allElementsBoundByIndex.first { $0.isHittable }
    }

    /// Back by the floating button, unfolding the chrome first if scrolling
    /// hid it.
    func goBack(file: StaticString = #filePath, line: UInt = #line) throws {
        let any = descendants(matching: .any)
        if any["tab-folded"].exists {
            any["tab-folded"].tap()
            _ = buttons["chrome-back"].waitForExistence(timeout: 3)
        }
        try XCTUnwrap(visible("chrome-back"), "no back button", file: file, line: line).tap()
    }

    /// A tab, with the tab bar unfolded first if scrolling folded it.
    func tab(_ name: String) -> XCUIElement {
        let any = descendants(matching: .any)
        if any["tab-folded"].exists {
            any["tab-folded"].tap()
            _ = any["tab-\(name)"].waitForExistence(timeout: 3)
        }
        return any["tab-\(name)"]
    }
}
