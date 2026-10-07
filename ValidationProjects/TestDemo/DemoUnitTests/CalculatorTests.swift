import XCTest

/// Plain XCTest coverage, plus three of the demo's sentinel-file triggers: `crash-unit`, `fail-once` and the runtime `XCTSkip`.
final class CalculatorTests: XCTestCase {
    func testAddition() {
        XCTAssertEqual(2 + 2, 4)
    }

    func testDivision() {
        XCTAssertEqual(10 / 2, 5)
    }

    /// `fail-once`: fails its first attempt and passes on any attempt after, recording the attempt itself by creating `.triggers/fail-once.seen`.
    ///
    /// `gates.sh` deletes `.seen` before each run it makes, so a fresh run always sees the first-attempt failure.
    func testFailsOnce() {
        guard Triggers.isSet("fail-once") else { return }
        guard Triggers.isSet("fail-once.seen") else {
            Triggers.set("fail-once.seen")
            XCTFail("first attempt under the fail-once trigger")
            return
        }
    }

    /// `crash-unit`: roughly the middle of this class alphabetically.
    func testMultiplyCrashesWhenTriggered() {
        if Triggers.isSet("crash-unit") {
            fatalError("boom")
        }

        XCTAssertEqual(3 * 4, 12)
    }

    func testSkipsWhenUnsupported() throws {
        throw XCTSkip("not supported on this configuration")
    }

    func testSubtraction() {
        XCTAssertEqual(9 - 4, 5)
    }
}
