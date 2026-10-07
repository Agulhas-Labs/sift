import XCTest

/// Four of the twelve UI tests, each launching the app fresh and making one small interaction on the items list.
///
/// Also carries the `hang` trigger.
@MainActor
final class ItemListUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testItemListAppears() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["itemRow.0"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
    }

    /// `hang`: sleeps forever rather than finishing, so a run against it never returns on its own.
    func testScrollsToLastItem() {
        let app = XCUIApplication()
        app.launch()
        if Triggers.isSet("hang") {
            while true {
                Thread.sleep(forTimeInterval: 60)
            }
        }
        app.staticTexts["itemRow.0"].swipeUp()
        Thread.sleep(forTimeInterval: 2)
    }

    func testSelectsFirstItem() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["itemRow.0"].waitForExistence(timeout: 30))
        app.staticTexts["itemRow.0"].tap()
        XCTAssertTrue(app.staticTexts["itemDetail.name"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)
    }

    func testTapsSecondItem() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["itemRow.1"].waitForExistence(timeout: 30))
        app.staticTexts["itemRow.1"].tap()
        XCTAssertTrue(app.staticTexts["itemDetail.name"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 8)
    }
}
