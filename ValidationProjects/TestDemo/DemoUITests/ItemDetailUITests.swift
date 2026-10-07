import XCTest

/// Four more of the twelve UI tests, each launching the app fresh and making one small interaction on the pushed detail screen.
@MainActor
final class ItemDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openFirstDetail(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.staticTexts["itemRow.0"].waitForExistence(timeout: 30))
        app.staticTexts["itemRow.0"].tap()
        XCTAssertTrue(app.staticTexts["itemDetail.name"].waitForExistence(timeout: 30))
    }

    func testDetailShowsIdentifier() {
        let app = XCUIApplication()
        openFirstDetail(app)
        XCTAssertTrue(app.staticTexts["itemDetail.id"].exists)
        Thread.sleep(forTimeInterval: 3)
    }

    func testDetailShowsName() {
        let app = XCUIApplication()
        openFirstDetail(app)
        XCTAssertTrue(app.staticTexts["itemDetail.name"].exists)
        Thread.sleep(forTimeInterval: 1)
    }

    func testNavigatesBackFromDetail() {
        let app = XCUIApplication()
        openFirstDetail(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["itemRow.0"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 6)
    }

    func testTitleMatchesItemName() {
        let app = XCUIApplication()
        openFirstDetail(app)
        XCTAssertTrue(app.navigationBars["Item 0"].exists)
        Thread.sleep(forTimeInterval: 20)
    }
}
