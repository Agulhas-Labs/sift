//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test process that ends on `exit(1)` or a `SIGKILL` prints no signal line: the answer still names the test it left unfinished, and never reads the run as a pass.
struct RunTestCrashWithoutSignalTests {
    /// `topples()` calls `exit(1)` while two other bundles pass: no signal line, one Swift Testing process with no closing count, and `topples()` started and never finished.
    @Test
    func anExitWithNoSignalLineNamesTheTestItLeftUnfinished() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        try filter.consume(Data(TestSources.runOutput("swift-test-exit-st").utf8))
        let stream = try TestSources.runOutputData("swift-test-exit-st", extension: "jsonl")
        try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: stream, encoding: .utf8))))
        let report = filter.finish(exitCode: 1)

        #expect(report.verdict?.state == .failed)
        #expect(report.isUsable(exitCode: 1))
        #expect(report.testCrash?.unfinished == ["topples()"])
        #expect(report.testCrash?.traps == [])
        let answer = Self.answer(report)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — exit 1 — test process crashed")
        #expect(lines.dropFirst().first == "  test process ended without a result (exit 1 / no signal line); started and never finished: topples()")
        #expect(lines.contains { $0.hasPrefix("totals: ✘ crashed") })
        #expect(!answer.contains("no trap message"))
        #expect(!answer.contains("Fatal error"))
    }

    /// `swift test` itself ended on a signal (exit 130): the tests it was running were interrupted, not lost to their own process, so no crash is read.
    @Test
    func aRunEndedOnItsOwnSignalIsNoUnsignalledCrash() {
        let report = Self.report(["◇ Test run started.", "◇ Test topples() started."], exitCode: 130)

        #expect(report.testCrash == nil)
    }

    /// A run whose Swift Testing process printed its closing count lost only an ending line, which is no crash however the run exited.
    @Test
    func aStartWithNoEndingInAClosedRunIsNoCrash() {
        let report = Self.report(
            ["◇ Test run started.", "◇ Test topples() started.", "✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue."],
            exitCode: 1
        )

        #expect(report.testCrash == nil)
    }

    /// An XCTest process that opened and never ended its outermost suite left `testBuckles` unfinished.
    @Test
    func anUnclosedXCTestProcessNamesItsUnfinishedTest() {
        let report = Self.report(
            [
                "Test Suite 'All tests' started at 2000-01-01 12:00:00.000.",
                "Test Suite 'PalletTests' started at 2000-01-01 12:00:00.000.",
                "Test Case '-[PalletTests.PalletTests testStacks]' started.",
                "Test Case '-[PalletTests.PalletTests testStacks]' passed (0.000 seconds).",
                "Test Case '-[PalletTests.PalletTests testBuckles]' started.",
            ],
            exitCode: 1
        )

        #expect(report.testCrash?.unfinished == ["-[PalletTests.PalletTests testBuckles]"])
        #expect(report.verdict?.state == .failed)
    }

    private static func report(_ lines: [String], exitCode: Int32) -> RunReport {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: exitCode)
    }

    private static func answer(_ report: RunReport) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
    }
}
