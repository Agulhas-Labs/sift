//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Swift Testing prints no suite beside a function's name, so the `totals:` skip count is the number of skip lines printed, whatever names they share.
struct RunSwiftTestingSharedNameSkipTests {
    private static func totals(of lines: [String]) -> String? {
        let arguments = ["swift", "test"]
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"), selector: RunTestSelector.named(in: arguments))
            .render(report, exitCode: 0, logURL: nil)
        return answer.split(separator: "\n").map(String.init).first { $0.hasPrefix("totals:") }
    }

    /// Two suites each skip a function of one name: both skips are counted.
    @Test
    func twoSuitesSkippingOneNameCountTwoSkips() {
        let lines = [
            "◇ Test run started.",
            "↩ Test anOrdinaryPass() skipped.",
            "↩ Test anOrdinaryPass() skipped.",
            "✔ Test run with 2 tests in 2 suites passed after 0.001 seconds.",
        ]

        #expect(Self.totals(of: lines) == "totals: ✔ passed · Swift Testing 2 tests in 2 suites, 2 skipped")
    }

    /// A skip followed by a pass of the same name in another suite still counts the skip.
    @Test
    func aSkipFollowedByAPassingTwinIsStillCounted() {
        let lines = [
            "◇ Test run started.",
            "↩ Test anOrdinaryPass() skipped.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Test run with 2 tests in 2 suites passed after 0.001 seconds.",
        ]

        #expect(Self.totals(of: lines) == "totals: ✔ passed · Swift Testing 2 tests in 2 suites, 1 skipped")
    }
}
