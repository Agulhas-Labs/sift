//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a test framework's line arriving glued behind output a test printed without a newline, which `xcodebuild` does on every run where a test prints that way: XCTest's `Test Case '…' passed (0.001 seconds).` straight after a printed `legacy`, `partial crate output✔ Test partial() passed after 0.003 seconds.`.
///
/// The capture is one real `xcodebuild test` of a package with fifteen Swift Testing tests and two `XCTestCase` tests; its result bundle counted 15 passed and 2 failed, one per test. Before the glued line was split, the live count read 12 passed of that run, and the report listed one failure with no message of its own.
struct XcodebuildGluedResultLineTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)
    private static var capture: String {
        "xcodebuild-test-glued-results"
    }

    /// The live state after `lines` arrive, each with its newline, in one chunk.
    private static func live(_ lines: [String]) -> RunLiveState {
        var tally = RunLiveTally(startedAt: start)
        tally.consume(Data(lines.map { $0 + "\n" }.joined().utf8), now: start)
        _ = tally.finish(now: start)
        return tally.state
    }

    /// The report the finished filter builds from `lines`.
    private static func report(_ lines: [String]) -> RunReport {
        var filter = RunOutputFilter(invokedAs: ["xcodebuild", "test"])
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: 65)
    }

    /// The live count of the captured run is the result bundle's, an XCTest ending and two Swift Testing endings glued behind printed output included.
    @Test
    func theLiveCountOfTheCaptureIsTheResultBundles() throws {
        let bytes = try TestSources.runOutputData(Self.capture, extension: "txt")
        var tally = RunLiveTally(startedAt: Self.start)
        tally.consume(bytes, now: Self.start)
        _ = tally.finish(now: Self.start)

        #expect(tally.state.tests.passed == 15)
        #expect(tally.state.tests.failed == 2)
        #expect(tally.state.tests.skipped == 0)
    }

    /// The finished report reads the glued endings the live count does, so the two cannot drift over them.
    @Test
    func theReportReadsTheGluedEndingsTheLiveCountDoes() throws {
        let report = try TestSources.runReport(Self.capture, invokedAs: ["xcodebuild", "test"], exitCode: 65)
        let endings = report.testOutcomes.lastEndings

        #expect(endings["-[PalletTests.LegacyTests testBuckles]"] == .passed)
        #expect(endings["third()"] == .passed)
        #expect(endings["partial()"] == .passed)
        #expect(endings.values.count { $0 == .passed } == 15)
        #expect(endings.values.count { $0 == .failed } == 2)
    }

    /// An issue line glued behind printed output keeps the location and the message it carries.
    @Test
    func anIssueLineGluedBehindOutputKeepsItsLocationAndMessage() throws {
        let report = try TestSources.runReport(Self.capture, invokedAs: ["xcodebuild", "test"], exitCode: 65)
        let broken = try #require(report.testFailures.first { $0.name == "broken()" })

        #expect(broken.location?.hasSuffix(".swift:14:27") == true)
        #expect(broken.message.hasPrefix("Expectation failed: double(2) == 5"))
    }

    /// A glued ending counts its test once, and the output in front of it counts nothing.
    @Test
    func aGluedEndingCountsItsTestOnce() {
        let lines = [
            "◇ Test inner() started.",
            "partial crate output✔ Test inner() passed after 0.003 seconds.",
            "Test Case '-[PalletTests.LegacyTests testBuckles]' started.",
            "legacy…Test Case '-[PalletTests.LegacyTests testBuckles]' passed (0.001 seconds).",
        ]
        let state = Self.live(lines)
        let endings = Self.report(lines).testOutcomes.lastEndings

        #expect(state.tests.passed == 2)
        #expect(state.tests.finished == 2)
        #expect(endings == ["inner()": .passed, "-[PalletTests.LegacyTests testBuckles]": .passed])
    }

    /// A line that reads from its head is never split, so an issue quoting an ending, or a `↳` note quoting one, counts no second test.
    @Test
    func aQuotedEndingIsNoTestsEnding() {
        let lines = [
            "◇ Test inner() started.",
            "✘ Test inner() recorded an issue at Crates.swift:3:5: Expectation failed: (log → \"✔ Test outer() passed after 0.001 seconds.\") == \"\"",
            "↳ the log said ✔ Test outer() passed after 0.001 seconds.",
            "✘ Test inner() failed after 0.002 seconds with 1 issue.",
        ]
        let state = Self.live(lines)
        let endings = Self.report(lines).testOutcomes.lastEndings

        #expect(state.tests.failed == 1)
        #expect(state.tests.finished == 1)
        #expect(endings == ["inner()": .failed])
    }

    /// An assertion's message quoting an XCTest ending mid-line is no glued line: the ending is not the whole rest of the line, so the message keeps its text and the quoted test counts nothing, even one the run started.
    @Test
    func anEndingQuotedInsideAnAssertionsMessageIsNotSplitOff() throws {
        let failing = "/Users/dev/Pallet/Tests/PalletTests/LegacyTests.swift:12: error: -[PalletTests.LegacyTests testDoubling] : "
        let message = "XCTAssertEqual failed: (\"Test Case '-[PalletTests.LegacyTests testBuckles]' passed (0.001 seconds).\") is not equal to (\"\")"
        let lines = [
            "Test Case '-[PalletTests.LegacyTests testBuckles]' started.",
            "Test Case '-[PalletTests.LegacyTests testDoubling]' started.",
            failing + message,
            "Test Case '-[PalletTests.LegacyTests testDoubling]' failed (0.002 seconds).",
        ]
        let state = Self.live(lines)
        let report = Self.report(lines)
        let failure = try #require(report.testFailures.first)

        #expect(state.tests.passed == 0)
        #expect(state.tests.failed == 1)
        #expect(report.testOutcomes.lastEndings == ["-[PalletTests.LegacyTests testDoubling]": .failed])
        #expect(report.testFailures.count == 1)
        #expect(failure.message == message)
    }

    /// A log line a test's child process prints, quoting a result line behind its own prefix, is no glued line: the test it names never started in this run, so it counts no failure and no pass.
    @Test
    func aPrefixedLogLineNamingATestTheRunNeverStartedIsNoEnding() {
        let lines = [
            "◇ Test inner() started.",
            "[child] ✘ Test outer() failed after 0.1 seconds with 1 issue.",
            "INFO ✔ Test stray() passed after 0.001 seconds.",
            "✔ Test inner() passed after 0.002 seconds.",
        ]
        let state = Self.live(lines)
        let report = Self.report(lines)

        #expect(state.tests.passed == 1)
        #expect(state.tests.failed == 0)
        #expect(report.testOutcomes.lastEndings == ["inner()": .passed])
        #expect(report.testFailures.isEmpty)
    }

    /// A child process forwarding its own run's lines behind a prefix opens no test for its ending: only a start read from its line's head lets a glued ending through.
    @Test
    func aPrefixedStartOpensNoTestForAPrefixedEnding() {
        let lines = [
            "[child] ◇ Test outer() started.",
            "[child] ✘ Test outer() failed after 0.1 seconds with 1 issue.",
            "◇ Test inner() started.",
            "✔ Test inner() passed after 0.002 seconds.",
        ]
        let state = Self.live(lines)
        let report = Self.report(lines)

        #expect(state.tests.passed == 1)
        #expect(state.tests.failed == 0)
        #expect(report.testOutcomes.lastEndings == ["inner()": .passed])
        #expect(report.testFailures.isEmpty)
    }

    /// A glued ending behind a SwiftPM lock notice is split off there too, so the live count and the report read the same test.
    @Test
    func aGluedEndingBehindALockNoticeCountsLiveAndInTheReport() {
        let lines = [
            "Test Case '-[PalletTests.LegacyTests testBuckles]' started.",
            "Another instance of SwiftPM is already running using '/Users/dev/Pallet/.build', waiting until that process has finished execution...legacy…Test Case '-[PalletTests.LegacyTests testBuckles]' passed (0.001 seconds).",
        ]
        let state = Self.live(lines)
        let endings = Self.report(lines).testOutcomes.lastEndings

        #expect(state.tests.passed == 1)
        #expect(endings == ["-[PalletTests.LegacyTests testBuckles]": .passed])
    }

    /// An XCTest assertion's shape inside other text — a parameterized case's argument, an echoed line — is no failure: the failure line opens on its file's path, so the run stays green.
    @Test
    func anXCTestFailureQuotedMidLineIsNoFailure() {
        let quoted = "/Users/dev/Pallet/Tests/PalletTests/LegacyTests.swift:12: error: -[PalletTests.LegacyTests testDoubling] : XCTAssertEqual failed"
        let (state, report) = Self.greenRun([
            "◇ Test labels(text:) started.",
            "◇ Test case passing 1 argument text → \"\(quoted)\" to labels(text:) started.",
            "said \(quoted)",
            "✔ Test labels(text:) with 1 test case passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ])

        #expect(state.errors == 0)
        #expect(state.tests.failed == 0)
        #expect(report.testFailures.isEmpty)
        #expect(report.errors.isEmpty)
        #expect(report.verdict?.state == .succeeded)
    }

    /// The report a `swift test` run that exited 0 builds from `lines`, and the live state after them.
    private static func greenRun(_ lines: [String]) -> (state: RunLiveState, report: RunReport) {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in lines {
            filter.consume(line: line)
        }
        return (live(lines), filter.finish(exitCode: 0))
    }

    /// A child process's run summary behind its own prefix is no run line of this run: the run's line names no test, so it is never split off, and a green run with one passing test stays green with one test.
    @Test
    func aChildsFailingRunSummaryLeavesAGreenRunGreen() {
        let (state, report) = Self.greenRun([
            "◇ Test run started.",
            "◇ Test inner() started.",
            "[child] ✘ Test run with 3 tests in 1 suite failed after 0.1 seconds with 2 issues.",
            "✔ Test inner() passed after 0.002 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.003 seconds.",
        ])

        #expect(state.tests == RunLiveState.Tests(passed: 1))
        #expect(report.verdict?.state == .succeeded)
        #expect(report.testFailures.isEmpty)
        #expect(report.testOutcomes.swiftTestingRuns.map(\.summaryTests) == [1])
    }

    /// A test echoing the run summary it expected is no run line either, so the run's own summary is the one counted.
    @Test
    func anEchoedRunSummaryIsNoRunLine() {
        let (state, report) = Self.greenRun([
            "◇ Test run started.",
            "◇ Test inner() started.",
            "expected output: ✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue.",
            "✔ Test inner() passed after 0.002 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.003 seconds.",
        ])

        #expect(state.tests == RunLiveState.Tests(passed: 1))
        #expect(report.verdict?.state == .succeeded)
        #expect(report.testFailures.isEmpty)
        #expect(report.testOutcomes.swiftTestingRuns.map(\.summaryTests) == [1])
    }

    /// An XCTest assertion is never split, even where its message ends on the whole of an ending for the test it is in: the message keeps the quoted ending and that test counts only the ending it printed.
    @Test
    func anAssertionEndingOnAQuotedEndingKeepsItsMessageWhole() throws {
        let message = "failed - expected Test Case '-[PalletTests.LegacyTests testBuckles]' passed (0.001 seconds)."
        let lines = [
            "Test Case '-[PalletTests.LegacyTests testBuckles]' started.",
            "/Users/dev/Pallet/Tests/PalletTests/LegacyTests.swift:12: error: -[PalletTests.LegacyTests testBuckles] : " + message,
            "Test Case '-[PalletTests.LegacyTests testBuckles]' failed (0.002 seconds).",
        ]
        let state = Self.live(lines)
        let report = Self.report(lines)
        let failure = try #require(report.testFailures.first)

        #expect(state.tests == RunLiveState.Tests(failed: 1))
        #expect(report.testOutcomes.lastEndings == ["-[PalletTests.LegacyTests testBuckles]": .failed])
        #expect(report.testFailures.count == 1)
        #expect(failure.message == message)
    }

    /// Each real shape of a Swift Testing ending glued behind printed text is split off and counts its test once: a failure carrying known issues, a cancellation with its comment, and a skip with and without one, a skip needing no start since a skipped test prints none.
    @Test(arguments: [
        (["◇ Test stacks() started.", "partial✘ Test stacks() failed after 0.001 seconds with 2 issues (including 1 known issue)."], RunLiveState.Tests(failed: 1), RunTestOutcomes.Ending.failed),
        (["◇ Test stacks() started.", "partial➜ Test stacks() was cancelled after 0.001 seconds: \"probe\""], RunLiveState.Tests(skipped: 1), .skipped),
        (["partial➜ Test stacks() skipped: \"not ready\""], RunLiveState.Tests(skipped: 1), .skipped),
        (["partial➜ Test stacks() skipped."], RunLiveState.Tests(skipped: 1), .skipped),
    ])
    func aGluedEndingInEachRealShapeCountsItsTestOnce(lines: [String], tests: RunLiveState.Tests, ending: RunTestOutcomes.Ending) {
        #expect(Self.live(lines).tests == tests)
        #expect(Self.report(lines).testOutcomes.lastEndings == ["stacks()": ending])
    }
}
