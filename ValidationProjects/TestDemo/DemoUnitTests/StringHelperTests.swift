import XCTest

final class StringHelperTests: XCTestCase {
    func testJoining() {
        XCTAssertEqual(["a", "b", "c"].joined(separator: "-"), "a-b-c")
    }

    func testTrimming() {
        XCTAssertEqual("  padded  ".trimmingCharacters(in: .whitespaces), "padded")
    }

    func testUppercasing() {
        XCTAssertEqual("demo".uppercased(), "DEMO")
    }
}
