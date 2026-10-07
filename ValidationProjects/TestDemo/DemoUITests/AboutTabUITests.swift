import XCTest

/// The last four of the twelve UI tests, each launching the app fresh and making one small interaction on the second tab.
///
/// Also carries the `crash-ui` trigger.
@MainActor
final class AboutTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openAboutTab(_ app: XCUIApplication) {
        app.launch()
        // By label, not identifier: an identifier set on a tab item's `Label` reaches the bar's button on some launches and
        // not others (three of four, on three simulators at once, 17 Sep 2026), while the label is always there.
        XCTAssertTrue(app.tabBars.buttons["About"].waitForExistence(timeout: 30))
        app.tabBars.buttons["About"].tap()
        XCTAssertTrue(app.staticTexts["aboutCounter"].waitForExistence(timeout: 20))
    }

    func testAboutScreenAppears() {
        let app = XCUIApplication()
        openAboutTab(app)
        Thread.sleep(forTimeInterval: 2)
    }

    /// `crash-ui`: roughly the middle of this class alphabetically.
    func testCounterIncrementsOnTap() {
        let app = XCUIApplication()
        openAboutTab(app)
        if Triggers.isSet("crash-ui") {
            fatalError("boom")
        }
        app.buttons["aboutTapButton"].tap()
        XCTAssertTrue(app.staticTexts["aboutCounter"].exists)
        Thread.sleep(forTimeInterval: 3)
    }

    func testSwitchesBackToItemsTab() {
        let app = XCUIApplication()
        openAboutTab(app)
        app.tabBars.buttons["Items"].tap()
        XCTAssertTrue(app.staticTexts["itemRow.0"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 5)
    }

    func testTapButtonMultipleTimes() {
        let app = XCUIApplication()
        openAboutTab(app)
        for _ in 0 ..< 3 {
            app.buttons["aboutTapButton"].tap()
        }
        Thread.sleep(forTimeInterval: 12)
    }
}
