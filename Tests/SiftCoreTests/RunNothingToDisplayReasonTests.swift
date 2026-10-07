//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Where no test process announced itself, the `totals:` line's reason says only what the run's evidence shows: that no process started is claimed over a build that failed first and nowhere else.
struct RunNothingToDisplayReasonTests {
    /// The line a gate would match, the one beginning with the token.
    private static func totalsLine(of answer: String) -> String? {
        answer.split(separator: "\n").first { $0.hasPrefix("totals:") }.map(String.init)
    }

    /// A filter that matched nothing (exit 4) says no test ran, never that no test process started: SwiftPM may launch the test binary only to find nothing to run.
    @Test
    func aFilterThatMatchedNothingSaysNoTestRan() throws {
        let arguments = ["swift", "test", "--filter", "aFailingTest"]
        let report = try TestSources.runReport("swift-test-no-match", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(report.testProcessOpenings == 0)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)

        #expect(Self.totalsLine(of: answer) == "totals: ✘ nothing ran — no test matched --filter aFailingTest · nothing to display, since no test ran")
    }

    /// A run that failed with no compiler or linker error and no test line says what the log shows — no process announced it started — rather than that none did.
    @Test
    func aFailureWithNoBuildErrorClaimsOnlyWhatTheLogShows() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(line: "error: the test runner could not be launched")
        let report = filter.finish(exitCode: 1)
        #expect(report.testProcessOpenings == 0)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: nil)

        let line = try #require(Self.totalsLine(of: answer))
        #expect(line.hasSuffix(" · nothing to display, since no test process announced that it started"), "\(line)")
    }
}
