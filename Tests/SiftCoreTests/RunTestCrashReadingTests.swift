//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Where a test process crash is read from a `swift test` log: the trap line after a Swift Testing issue's note, and never a crash in a run that exited 0.
struct RunTestCrashReadingTests {
    /// The Swift Testing test recorded an issue and then trapped: the trap line printed straight after the issue's `↳` lines is quoted, and the note keeps only its own lines.
    @Test
    func aTrapPrintedRightAfterAnIssuesNoteIsStillQuoted() throws {
        let report = try TestSources.runReport("swift-test-crash-st-issue", invokedAs: ["swift", "test", "--filter", "topples", "--filter", "testStacks"], exitCode: 1)

        #expect(report.testCrash?.traps == ["PalletTests/Stacking.swift:12: Fatal error: Unexpectedly found nil while unwrapping an Optional value"])
        #expect(report.testFailures.count == 1)
        let answer = Self.answer(report, exitCode: 1)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — exit 1 — test process crashed")
        #expect(lines.dropFirst().first == "  PalletTests/Stacking.swift:12: Fatal error: Unexpectedly found nil while unwrapping an Optional value")
        #expect(!answer.contains("no trap message"))
        #expect(lines.contains { $0.contains("↳ the shelf is empty") && !$0.contains("Fatal error") })
    }

    /// A passing test printed SwiftPM's signal line and the run exited 0: no process died, so the answer is the pass and names no crash.
    @Test
    func aSignalLineAPassingTestPrintedInARunThatExitedZeroIsNoCrash() {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in [
            "◇ Test run started.",
            "◇ Test topples() started.",
            "error: Process '/usr/bin/xctest -XCTest PalletTests.PalletTests/testStacks /Users/dev/Pallet/x' exited with unexpected signal code 5",
            "✔ Test topples() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        #expect(report.testCrash == nil)
        #expect(report.verdict?.state == .succeeded)
        let answer = Self.answer(report, exitCode: 0)
        #expect(answer.hasPrefix("✔ swift test\n"))
        #expect(answer.contains("totals: ✔ passed · Swift Testing 1 test in 0 suites"))
        #expect(!answer.contains("crashed"))
    }

    private static func answer(_ report: RunReport, exitCode: Int32) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: exitCode, logURL: nil)
    }
}
