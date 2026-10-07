//
// Copyright © Agulhas Labs
//

import Foundation

/// Everything a filtered run kept, and the size of the log it kept it from.
///
/// It counts the input and nothing about the output. A count of shown lines, accumulated one line at a time as the stream is parsed, stops being a description of the answer the moment the failures are served as a *shape* rather than a listing: on the failing capture it would count 1,302 lines as shown while 23 are printed, and the receipt beneath them would understate the saving by 1,279. An answer's size is a property of the answer, so it is measured on the rendered text — see ``RunReportRenderer`` — and no second count is kept here to disagree with it.
public struct RunReport: Sendable {
    public let errors: [RunDiagnostic]
    public let warnings: [RunDiagnostic]
    public let testFailures: [RunTestFailure]
    /// The tool's own summary lines, verbatim and in the order the tool would have printed them.
    public let summaryLines: [String]
    /// What the invoked command committed to printing, which is what makes an absent verdict readable as absent.
    ///
    /// Carried alongside the verdict because ``verdict`` being `nil` has two meanings and the answer has to word them differently: the log ran out without declaring anything, or the log declared something this tool refused to read because it could not tell which line the action owed. Only the contract knows which — ``RunVerdict/Contract/unreadable`` *is* the second — and a report that dropped it would leave the headline claiming there was no verdict in a log that quotes one two lines below.
    public let contract: RunVerdict.Contract
    /// How the run ended, or `nil` when there is none to give — see ``contract`` for which of the two silences that is.
    public let verdict: RunVerdict?
    /// Swift Testing's closing count, when the run printed exactly one.
    ///
    /// `nil` where it printed several, which a two-bundle `xcodebuild test` does: the counts are per test process and there is no honest single value to stand for them. The lines themselves are all in ``summaryLines``.
    public let tally: RunTestTally?
    /// How many lines the wrapped command printed — the whole of what the answer stands in for.
    public let totalLines: Int
    /// Every test the run reported starting or finishing, passes included — empty for a run that never reached its tests.
    public let testOutcomes: RunTestOutcomes
    /// How many times the log announced a test process starting, which is what says how many processes a closing count is owed *from*.
    ///
    /// `swift test` runs two processes per test product, not one: the XCTest harness, which writes `Test Suite 'All tests' started at …` once as it opens and runs whether or not the package holds a single `XCTestCase`, and the separate `swiftpm-testing-helper` process that carries every `@Test`, which writes `Test run started.` once as *it* opens. A crash probe kills one while the other keeps running, and the mirror probe's error names the helper by its own path — proof the two are distinct processes rather than one printing both lines — so this is the sum of both openings, never the greater of the two closing counts they owe, which is a different fact about the same run.
    ///
    /// **What it cannot see is a bundle that never launched.** A test target that failed to compile announces nothing, so this number is a count of processes that *started*, never of bundles the package has — the one case left undecidable, and worded that way wherever it is read.
    public let testProcessOpenings: Int
    /// How many of those processes are known to have printed a closing count — XCTest's `Executed …`, vestigial or not, and Swift Testing's `Test run with …` — summed the same way ``testProcessOpenings`` is.
    ///
    /// Kept apart from what the answer actually shows: an XCTest counter that states nothing (`Executed 0 tests, with 0 failures`) still means that process closed, even though the answer does not print a line that says so. Fewer of these than ``testProcessOpenings`` is a process that opened and never closed — a crash, a `fatalError`, a timeout — which an answer reading only the printed counts cannot otherwise tell from a run that simply had one process to begin with.
    public let testProcessClosings: Int
    /// How many of ``testProcessOpenings`` were Swift Testing's, one `Test run started.` each, which is how many `Test run with …` lines the log owes.
    public let swiftTestingProcessOpenings: Int
    /// Whether the invocation carried `--parallel`, which changes what the log says a `swift test` closing count is worth.
    ///
    /// Under it SwiftPM prints no XCTest opening or closing count for the tests it actually ran in parallel — only `[k/N] Testing <name>` progress lines this filter does not read as either — and, on any failure, reruns the failing test alone and prints an ordinary XCTest count for that rerun. So a passing run under the flag owes no XCTest count at all, and a failing one's own count is of the rerun, not of everything the run executed; both are true regardless of ``testProcessOpenings``, which the flag leaves looking unremarkable.
    public let parallelSwiftTest: Bool
    /// Whether the log printed `xcodebuild`'s own `Testing cancelled because the build failed.` — positive evidence a build failure, not a test, is why nothing ran, for a build failure whose compiler error carries no `file:line` (a signing failure, a missing build input file).
    public let cancelledForBuildFailure: Bool
    /// Whether the log printed `xcodebuild`'s own `Failing tests:` heading — proof a named test failed, which vetoes ``RunTestSelector/didNotBuild(_:exitCode:)`` even where a `-quiet` run's own failure line otherwise reads like a compiler error with a `file:line`.
    public let namedFailingTests: Bool
    /// The compiler crash the log reported, or `nil` where it reported none — an explanation of a failed run on its own, with no error line to list.
    public let compilerCrash: RunCompilerCrash?
    /// The line saying a `swift test` run's event stream and its console disagreed on how many Swift Testing tests ended, and which the answer read; `nil` where they agreed or there was no stream to read.
    public let eventStreamNote: String?
    /// The identifier of every test function a `swift test` run's event stream declared, verbatim; `nil` where no stream was read.
    public let streamedTestIDs: Set<String>?
    /// The test process that died on a signal, or `nil` where none did — an explanation of a failed run on its own, and never a pass.
    public let testCrash: RunTestCrash?

    public init(
        errors: [RunDiagnostic],
        warnings: [RunDiagnostic],
        testFailures: [RunTestFailure],
        summaryLines: [String],
        contract: RunVerdict.Contract,
        verdict: RunVerdict?,
        tally: RunTestTally?,
        totalLines: Int,
        testOutcomes: RunTestOutcomes = RunTestOutcomes(),
        testProcessOpenings: Int = 0,
        testProcessClosings: Int = 0,
        parallelSwiftTest: Bool = false,
        cancelledForBuildFailure: Bool = false,
        namedFailingTests: Bool = false,
        swiftTestingProcessOpenings: Int = 0,
        compilerCrash: RunCompilerCrash? = nil,
        eventStreamNote: String? = nil,
        streamedTestIDs: Set<String>? = nil,
        testCrash: RunTestCrash? = nil
    ) {
        self.testCrash = testCrash
        self.eventStreamNote = eventStreamNote
        self.streamedTestIDs = streamedTestIDs
        self.swiftTestingProcessOpenings = swiftTestingProcessOpenings
        self.errors = errors
        self.warnings = warnings
        self.testFailures = testFailures
        self.summaryLines = summaryLines
        self.contract = contract
        self.verdict = verdict
        self.tally = tally
        self.totalLines = totalLines
        self.testOutcomes = testOutcomes
        self.testProcessOpenings = testProcessOpenings
        self.testProcessClosings = testProcessClosings
        self.parallelSwiftTest = parallelSwiftTest
        self.cancelledForBuildFailure = cancelledForBuildFailure
        self.namedFailingTests = namedFailingTests
        self.compilerCrash = compilerCrash
    }
}

public extension RunReport {
    /// How many test bundles this run was heard from — the greater of the two frameworks' closing-count tallies, never their sum.
    ///
    /// One bundle prints at most one line of each shape, so a bundle heard from twice would be counted twice by a sum, while one that printed only a Swift Testing tally, or only an XCTest counter, still reported. Stated here rather than worked out again at each site that needs it: the answer's `totals:` line and the judgement of whether a run may stand for its tree both turn on it, and two copies of the rule are two places for it to drift.
    var reportedBundleCount: Int {
        let swiftTesting = summaryLines.filter { RunOutputFilter.undecorated($0).hasPrefix("Test run with ") }.count
        let xctest = summaryLines.filter { $0.hasPrefix("Executed ") }.count
        return max(swiftTesting, xctest)
    }

    /// Whether the filtered answer is worth serving instead of the raw output.
    ///
    /// The one case it is not: the command failed and the filter found nothing that says why. Serving a cheerful "no errors" over a nonzero exit would be the worst outcome this tool can produce, so the raw log goes out whole instead.
    ///
    /// **A summary line is a verdict, not an explanation**, and is deliberately not counted here. Counting it would make this state unreachable for the one tool whose logs are longest: `** BUILD FAILED **` / `** TEST FAILED **` is captured on *every* failing `xcodebuild`, so a test-runner crash would answer `✘ xcodebuild — exit 65` over that verdict alone while the two lines that said why (`Testing failed:`, `Test runner exited before starting test execution.`) were suppressed — exactly what Docs/Design.md §3 rule 4 forbids. `Build complete!` standing over a nonzero exit is the same mistake in a friendlier voice. Only a diagnostic, a named test failure or a compiler crash explains a failure; every summary line restates the exit code the caller already has.
    ///
    /// **A missing `verdict` is deliberately not read here either**, and for the mirror-image reason. The danger it names — a log that stops mid-run — arrives with exit 0 far more often than not (a killed `xcodebuild` under a wrapper, a truncated capture), and this test lets every exit-0 report through. So the loudness has to live in the answer that gets served, not in a gate that would never fire; `RunReportRenderer` says it in the headline, which is the one line a caller always reads. The exception is `xcodebuild -quiet`, whose clean run prints no verdict either: its silence over exit 0 is read as a pass (``RunVerdict/inferredFromExitCode``), a `-quiet` log cut short with exit 0 cannot be told apart from one, and the answer says the pass rests on the exit code for exactly that reason.
    func isUsable(exitCode: Int32) -> Bool {
        guard exitCode != 0 else {
            return true
        }
        if compilerCrash != nil || testCrash != nil {
            return true
        }
        // A linter has no errors/warnings distinction that decides whether the run is explained: `swiftlint
        // lint --strict` fails on a warning-severity rule alone, still spelled `warning:`, so a diagnostics
        // report with nothing but warnings is exactly as explained as one with an error in it.
        if contract == .diagnostics {
            return !errors.isEmpty || !warnings.isEmpty
        }
        return !errors.isEmpty || !testFailures.isEmpty
    }
}
