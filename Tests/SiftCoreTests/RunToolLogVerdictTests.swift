//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a timestamped tool-log line (`<date> <time> tool[pid:tid] error: …`) may change about a run: nothing but the lines the answer shows.
///
/// Each case is a run whose verdict, exit code and explanation were already right before the line was read at all, held against that reading with the line in its log: a line a test logged itself, a selector that matched nothing, a `-quiet` pass, a passing build's proof, and a failure the line must not stand in for.
struct RunToolLogVerdictTests {
    /// The line `appintentsnltrainingprocessor` logs beside builds that succeed.
    private static var archiveError: String {
        "2026-10-09 18:30:12.100 appintentsnltrainingprocessor[58835:11885402] error: Could not archive SSU artifacts. Check build log."
    }

    /// What a passing XCTest logged itself, in the shape every tool's log line takes.
    private static var loggedByTheTest: String {
        "2026-10-09 18:30:13.200 xctest[58836:11885403] error: logged by the test on purpose"
    }

    /// A passing XCTest that logs an `error:` line of its own is still a pass, and its proof is recorded.
    @Test
    func aPassingTestThatLogsAnErrorStillPasses() throws {
        let arguments = ["swift", "test", "--filter", "LegacyTests"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = Self.xctestReport(["-[LibTests.LegacyTests testPasses]"], invokedAs: arguments)

        #expect(report.errors.isEmpty)
        #expect(report.toolLog.isEmpty)
        let answer = Self.answer(report, kind: .swiftTest, exitCode: 0, selector: selector)
        #expect(answer.hasPrefix("✔ swift test"))
        #expect(!answer.contains("✘"))
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
        let outcome = RunOutcome(kind: .swiftTest, logKey: "swift test", exitCode: 0, report: report, log: nil, repositoryRoot: nil)
        #expect(outcome.provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// A test that logs a line shaped like an XCTest assertion, in a tool-log line's timestamped form, is still a pass: the line is shown, never judged.
    @Test
    func aToolLogLineShapedLikeAnAssertionIsNotAFailure() throws {
        let arguments = ["swift", "test", "--filter", "LegacyTests"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let name = "-[LibTests.LegacyTests testPasses]"
        let tally = "\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
        let report = Self.report(of: [
            "Build complete! (0.98s)",
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.346.",
            "Test Case '\(name)' started.",
            "2026-10-09 18:30:12.100 xctest[1:2] error: -[LibTests.Other testX] : XCTAssertTrue failed",
            "Test Case '\(name)' passed (0.000 seconds).",
            "Test Suite 'Selected tests' passed at 2000-01-01 12:00:00.347.",
            tally,
        ], invokedAs: arguments, exitCode: 0)

        #expect(report.testFailures.isEmpty)
        let answer = Self.answer(report, kind: .swiftTest, exitCode: 0, selector: selector)
        #expect(answer.hasPrefix("✔ swift test"))
        #expect(!answer.contains("Other.testX"))
        #expect(!answer.contains("✘"))
    }

    /// Beside a test that logs an `error:` line, a `--filter` that matched nothing is still named, and the run still exits 4.
    @Test
    func aFilterThatMatchedNothingIsStillNamedBesideATestThatLogsAnError() throws {
        let arguments = ["swift", "test", "--filter", "LegacyTests/testPasses", "--filter", "NothingLikeThis"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = Self.xctestReport(["-[LibTests.LegacyTests testPasses]"], invokedAs: arguments)

        let headline = Self.answer(report, kind: .swiftTest, exitCode: 0, selector: selector).split(separator: "\n").first.map(String.init)

        #expect(headline == "✘ swift test — no test matched --filter NothingLikeThis — 1 of 2 filters (the command exited 0; sift run exits 4)")
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
    }

    /// An `-only-testing:` identifier that matched nothing is still nothing ran, and exits 4, with the tool's `error:` line in the build.
    @Test
    func anOnlyTestingIdentifierThatMatchedNothingStillRanNothing() throws {
        let arguments = ["xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo", "test", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"]
        let lines = try [Self.archiveError] + TestSources.runOutput("xcodebuild-test-no-match").components(separatedBy: "\n")
        let report = Self.report(of: lines, invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(report.toolLog.count == 1)
        let headline = Self.answer(report, kind: .xcodebuild, exitCode: 0, selector: selector).split(separator: "\n").first.map(String.init)
        #expect(headline?.hasPrefix("✘ xcodebuild — nothing ran: no test matched -only-testing:GizmoTests/GizmoTests/aTrendIsRead (the command exited 0; sift run exits 4)") == true)
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
    }

    /// A `-quiet` build that exited 0 is still read as passed off its exit code, and the line is shown beneath.
    @Test
    func aQuietBuildThatLoggedAToolErrorIsStillReadAsPassed() throws {
        let report = Self.report(of: [Self.archiveError], invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"], exitCode: 0)

        let verdict = try #require(report.verdict)
        #expect(verdict.state == .succeeded)
        #expect(verdict.inferredFromExitCode)
        let lines = Self.answer(report, kind: .xcodebuild, exitCode: 0).components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("✔ xcodebuild") == true)
        #expect(lines.contains("tool log (1):"))
        #expect(lines.contains("  appintentsnltrainingprocessor: error: Could not archive SSU artifacts. Check build log."))
    }

    /// A build that printed its success banner beside the line proves green.
    @Test
    func aPassingBuildThatLoggedAToolErrorProvesGreen() {
        let report = Self.report(of: [Self.archiveError, "** BUILD SUCCEEDED **"], invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build"], exitCode: 0)

        #expect(report.errors.isEmpty)
        let outcome = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild build", exitCode: 0, report: report, log: nil, repositoryRoot: nil)
        #expect(outcome.provedGreen(testBundles: .undetermined))
    }

    /// A failed build whose cause the filter cannot read is not explained by the line: the raw output is served, as it was without it.
    @Test
    func aToolErrorDoesNotExplainAFailedBuild() {
        let lines = ["The sandbox refused to let the build write its products", Self.archiveError, "** BUILD FAILED **"]
        let report = Self.report(of: lines, invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build"], exitCode: 65)

        #expect(report.errors.isEmpty)
        #expect(report.toolLog.count == 1)
        #expect(!report.isUsable(exitCode: 65))
    }

    /// A live tally counts no tool-log line as an error of the build's.
    @Test
    func theLiveTallyDoesNotCountAToolError() {
        var tally = RunLiveTally(startedAt: Date(timeIntervalSinceReferenceDate: 0))
        tally.consume(line: Self.archiveError, now: Date(timeIntervalSinceReferenceDate: 1))

        #expect(tally.state.errors == 0)
        #expect(tally.state.warnings == 0)
    }

    /// An XCTest-only `swift test` console that ran each of `names` in one bundle and passed, each test logging ``loggedByTheTest`` while it ran, after a build that printed nothing.
    private static func xctestReport(_ names: [String], invokedAs arguments: [String]) -> RunReport {
        var lines = [
            "Build complete! (0.98s)",
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.346.",
            "Test Suite 'LibTests.xctest' started at 2000-01-01 12:00:00.346.",
        ]
        for name in names {
            lines += ["Test Case '\(name)' started.", loggedByTheTest, "Test Case '\(name)' passed (0.000 seconds)."]
        }
        let tally = "\t Executed \(names.count) tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
        lines += [
            "Test Suite 'LibTests.xctest' passed at 2000-01-01 12:00:00.347.",
            tally,
            "Test Suite 'Selected tests' passed at 2000-01-01 12:00:00.347.",
            tally,
        ]
        return report(of: lines, invokedAs: arguments, exitCode: 0)
    }

    private static func report(of lines: [String], invokedAs arguments: [String], exitCode: Int32) -> RunReport {
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: exitCode)
    }

    private static func answer(_ report: RunReport, kind: RunCommandKind, exitCode: Int32, selector: RunTestSelector? = nil) -> String {
        RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet"), selector: selector)
            .render(report, exitCode: exitCode, logURL: nil)
    }
}
