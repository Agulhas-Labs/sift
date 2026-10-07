//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which runs are in a position to say what failed in them — the three-state answer the whole per-test history rests on.
///
/// `[]` and `nil` are different claims and only one of them is a measurement. Every test here is about a run that must answer `nil`, because those are the ones that would otherwise be counted as runs where nothing failed.
struct RunRecordedFailuresTests {
    @Test
    func aFilteredRunNamesTheTestsItReportedFailing() {
        let outcome = Self.outcome(exitCode: 1, testFailures: ["theWellIsATarget()", "aGridReflows()"])

        #expect(outcome.reportedTestFailures == ["theWellIsATarget()", "aGridReflows()"])
    }

    /// A run that read its own output and found nothing failing answers with an empty list, which is what gives every other count a denominator.
    @Test
    func aCleanRunAnswersWithAnEmptyList() {
        let outcome = Self.outcome(exitCode: 0, testFailures: [])

        #expect(outcome.reportedTestFailures == [])
    }

    /// A passthrough ran no filter, so nothing read its output and nothing can be said about it.
    @Test
    func aPassthroughAnswersUnknown() {
        let outcome = RunOutcome(kind: .unrecognized, logKey: "unfiltered", exitCode: 0, report: nil, log: nil, repositoryRoot: nil)

        #expect(outcome.reportedTestFailures == nil)
    }

    /// A failure the filter could not explain is unknown, not clean.
    ///
    /// This is the fail-open branch: the raw log went out precisely because nobody knows what went wrong, and a test runner that crashed before reporting takes its whole suite down without naming one of them. Counting that as a run everything passed in is the wrong answer this field exists to avoid.
    @Test
    func aFailureTheFilterCouldNotExplainAnswersUnknown() {
        let outcome = Self.outcome(exitCode: 65, testFailures: [])

        #expect(outcome.reportedTestFailures == nil)
    }

    /// A run that failed on diagnostics and named no failing test never reached its tests, and a test that did not run did not pass.
    @Test
    func aRunThatFailedToCompileAnswersUnknown() {
        let outcome = Self.outcome(
            exitCode: 1,
            testFailures: [],
            errors: [RunDiagnostic(severity: .error, path: "Widget.swift", line: 4, column: 9, message: "cannot find 'nope' in scope", detail: [])]
        )

        #expect(outcome.reportedTestFailures == nil)
    }

    /// Diagnostics beside named failures are still an answer: the suite ran, and these are the tests it reported.
    @Test
    func errorsAlongsideNamedFailuresStillAnswer() {
        let outcome = Self.outcome(
            exitCode: 1,
            testFailures: ["theWellIsATarget()"],
            errors: [RunDiagnostic(severity: .error, path: "Widget.swift", line: 4, column: 9, message: "no such module", detail: [])]
        )

        #expect(outcome.reportedTestFailures == ["theWellIsATarget()"])
    }

    /// A run whose log stopped before declaring anything cannot say what failed in it, whatever its failure list looks like.
    ///
    /// The list looks *clean*: a truncated capture, or one whose action this tool would not read, arrives with no failures and no errors, so a reading of the list alone answers `[]` — a run that read its own output and found nothing wrong. That is filed as `"failed": [], "failed_total": 0` and counted into every denominator `flakes` divides by, while the same report's headline reads `⚠ … no verdict in the log`. Two consumers of one answer, contradicting each other.
    @Test
    func aRunWithNoVerdictAnswersUnknown() {
        let silent = Self.outcome(exitCode: 0, testFailures: [], verdict: nil)
        let named = Self.outcome(exitCode: 1, testFailures: ["theWellIsATarget()"], verdict: nil)

        #expect(silent.reportedTestFailures == nil)
        // Not even where it named one: a log that never said how it ended did not say it had finished
        // naming them either.
        #expect(named.reportedTestFailures == nil)
    }

    /// A run that was killed is in the same position, and its own headline already says so.
    ///
    /// `◼ … interrupted` is the third state precisely because the run never got to judge itself, so whatever it had named by then is a fragment of a suite that did not finish rather than a statement about one.
    @Test
    func anInterruptedRunAnswersUnknown() {
        let interrupted = RunVerdict(state: .interrupted, line: "** BUILD INTERRUPTED **", owed: nil)
        let outcome = Self.outcome(exitCode: 130, testFailures: ["theWellIsATarget()"], verdict: interrupted)

        #expect(outcome.reportedTestFailures == nil)
    }

    /// A run that declared how it ended, which is the ordinary case and the premise of every test above that is not about the verdict.
    ///
    /// The verdict is stated rather than left `nil`: a fixture built with none runs through the no-verdict branch, and `aCleanRunAnswersWithAnEmptyList` would then pin that branch's answer rather than a clean run's.
    private static func outcome(exitCode: Int32, testFailures: [String], errors: [RunDiagnostic] = []) -> RunOutcome {
        outcome(
            exitCode: exitCode,
            testFailures: testFailures,
            errors: errors,
            verdict: RunVerdict(state: exitCode == 0 ? .succeeded : .failed, line: nil, owed: nil)
        )
    }

    /// The same run with its verdict stated outright, for the tests whose subject the verdict is.
    private static func outcome(
        exitCode: Int32,
        testFailures: [String],
        errors: [RunDiagnostic] = [],
        verdict: RunVerdict?
    ) -> RunOutcome {
        RunOutcome(
            kind: .swiftTest,
            logKey: "swift test",
            exitCode: exitCode,
            report: RunReport(
                errors: errors,
                warnings: [],
                testFailures: testFailures.map { RunTestFailure(name: $0, location: nil, message: "failed") },
                summaryLines: [],
                contract: .runTally,
                verdict: verdict,
                tally: nil,
                totalLines: 100
            ),
            log: nil,
            repositoryRoot: nil
        )
    }
}
