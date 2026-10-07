//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A suite whose type is a raw identifier (`` `a.b` ``, `` `a/b` ``): one unit however many dots or slashes its name holds.
struct PackageShardRawSuiteTests {
    private static func test(_ listed: String) -> TestIdentifier {
        ((try? PackageShardPlanner.listed(listed)) ?? []).first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    private static func event(_ kind: String, _ identifier: String, at instant: Double) -> String {
        #"{"kind":"event","payload":{"instant":{"absolute":\#(instant),"since1970":0},"kind":"\#(kind)","messages":[],"testID":"\#(identifier)"},"version":0}"#
    }

    @Test func aDottedRawIdentifierSuiteIsOneUnitWithItsNestedSuites() {
        #expect(PackageShardPlanner.suite(of: Self.test("LibTests.`a.b`/test()")) == "LibTests.`a.b`")
        #expect(PackageShardPlanner.suite(of: Self.test("LibTests.`a.b`.Inner/test()")) == "LibTests.`a.b`")
        #expect(PackageShardPlanner.suite(of: Self.test("LibTests.Outer.`a.b`/test()")) == "LibTests.Outer")
    }

    @Test func aRawIdentifierSuiteAndItsSpanAreKeyedTheSame() {
        for (listed, streamed) in [
            ("LibTests.`a.b`/test()", #"LibTests.`a.b`\/test()\/F.swift:3:6"#),
            ("LibTests.`a/b`/test()", #"LibTests.`a\/b`\/test()\/F.swift:3:6"#),
        ] {
            let suite = PackageShardPlanner.suite(of: Self.test(listed))
            let stream = [Self.event("testStarted", streamed, at: 1), Self.event("testEnded", streamed, at: 4)].joined(separator: "\n")

            #expect(SuiteSpans.read(stream) == [suite: 3], "\(listed)")
        }
    }

    @Test func theFilterAndTheSwiftTestingSuitesStillSelectARawIdentifierSuite() throws {
        let tests = [Self.test("LibTests.`a.b`/test()"), Self.test("LibTests.`a.b`.Inner/other()")]
        let pattern = PackageShardPlanner.filter(for: tests)
        let regex = try NSRegularExpression(pattern: pattern)

        #expect(pattern == #"^(?:LibTests\.`a\.b`)[/.]"#)
        #expect(regex.firstMatch(in: "LibTests.`a.b`/test()", range: NSRange(location: 0, length: 21)) != nil)
        #expect(PackageShardPlanner.swiftTestingSuites(listed: "LibTests.`a.b`/test()\nLibTests.`a.b`.Inner/other()") == ["LibTests.`a.b`"])
    }
}
