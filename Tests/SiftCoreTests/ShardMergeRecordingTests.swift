//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a reconciliation offers `TestDurationStore` — a retry's attempts, a genuine failure's passed tests — and the notes a shard ended at its bound or that never started carries.
///
/// The suite carries `.temporaryDirectories` for the same reason `ShardMergeTests` does: what a reconciliation is *for* is partly what the duration store does with it, and that store is a file in a repository.
@Suite(.temporaryDirectories)
struct ShardMergeRecordingTests {
    private func identifier(_ enumerated: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> TestIdentifier {
        try #require(TestIdentifier(enumerated: enumerated), sourceLocation: sourceLocation)
    }

    /// The nine `XCTestCase` methods the demo project's unit bundle declares, in enumeration order.
    private func demoUnitTests(sourceLocation: SourceLocation = #_sourceLocation) throws -> [TestIdentifier] {
        let calculator = ["testAddition", "testDivision", "testFailsOnce", "testMultiplyCrashesWhenTriggered", "testSkipsWhenUnsupported", "testSubtraction"]
        let strings = ["testJoining", "testTrimming", "testUppercasing"]
        return try calculator.map { try identifier("DemoUnitTests/CalculatorTests/\($0)()", sourceLocation: sourceLocation) }
            + strings.map { try identifier("DemoUnitTests/StringHelperTests/\($0)()", sourceLocation: sourceLocation) }
    }

    private func outcomes(_ fixture: String) throws -> RunTestOutcomes {
        var read = RunTestOutcomes()
        for line in try TestSources.runOutput(fixture).components(separatedBy: "\n") {
            read.read(line)
        }
        return read
    }

    /// Outcomes read from written lines, for the shapes no capture carries: a shard's log ending one name more often than that shard has tests declaring it is a runner defect, and no run of the demo project prints one.
    private func outcomes(reading lines: [String]) -> RunTestOutcomes {
        var read = RunTestOutcomes()
        for line in lines {
            read.read(line)
        }
        return read
    }

    private func plan(_ shards: [[TestIdentifier]], displayNames: [String: [TestIdentifier]] = [:]) -> ShardPlan {
        ShardPlan(
            shards: shards.enumerated().map { index, tests in
                ShardPlan.Shard(index: index + 1, tests: tests, predictedSeconds: 20 + Double(tests.count))
            },
            requestedShards: shards.count,
            overheadSeconds: 20,
            estimatedTests: 0,
            estimatedSeconds: 1,
            displayNames: displayNames,
            lowering: nil
        )
    }

    private func shard(_ outcomes: RunTestOutcomes, exitCode: Int32 = 0, wallSeconds: Double = 30, log: String = "/tmp/shard.log") -> ShardOutcome {
        ShardOutcome(outcomes: outcomes, exitCode: exitCode, wallSeconds: wallSeconds, logPath: log)
    }

    /// A test that failed and was retried is one test that passed: the attempts are one test's, the last of them is its outcome, and neither reading makes it two tests or a duplicate.
    @Test
    func aRetriedTestIsOneTestEndingAsItsLastAttemptDid() throws {
        let tests = try demoUnitTests()

        let merged = try ShardMerge.reconcile(plan: plan([tests]), outcomes: [shard(outcomes("xcodebuild-retry-iterations"))])

        #expect(merged.counts == ShardReconciliation.Counts(expected: 9, ran: 9, passed: 8, failed: 0, skipped: 1, missing: 0, duplicated: 0))
        #expect(merged.failed.isEmpty)
        #expect(merged.duplicated.isEmpty)
        #expect(merged.isGreen)
        #expect(merged.exitCode == 0)
    }

    /// A first attempt that failed before its retry passed is an attempt: it is not listed as a failure under a count reading `failed 0`, and the answer says the shard repeated tests.
    @Test
    func aFailureARetryOvertookIsNotListedAsAFailure() throws {
        let tests = try demoUnitTests()
        let overtaken = RunTestFailure(name: "-[DemoUnitTests.CalculatorTests testFailsOnce]", arguments: nil, location: "CalculatorTests.swift:20", message: "failed - first attempt", note: nil)
        let stray = RunTestFailure(name: "-[OtherTarget.GizmoTests testNothing]", arguments: nil, location: nil, message: "failed", note: nil)
        var outcome = try shard(outcomes("xcodebuild-retry-iterations"))
        outcome = ShardOutcome(outcomes: outcome.outcomes, exitCode: 0, wallSeconds: 30, logPath: outcome.logPath, failures: [overtaken, stray])

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [outcome])

        #expect(merged.counts.failed == 0)
        #expect(merged.failures.map(\.name) == ["-[OtherTarget.GizmoTests testNothing]"])
        #expect(merged.notes.contains { $0.hasPrefix("shard 1 repeated tests, up to attempt") })
    }

    /// A shard that retried offers the duration store a recording that says so, which is what stops a timing taken beside a retry from being kept.
    @Test
    func aShardThatRetriedSaysSoInItsRecording() throws {
        let tests = try demoUnitTests()

        let merged = try ShardMerge.reconcile(plan: plan([tests]), outcomes: [shard(outcomes("xcodebuild-retry-iterations"))])

        let recording = try #require(merged.recording(forShard: 1))

        #expect(recording.retried)
        #expect(recording.missing == 0)
        #expect(merged.shards[0].iterations == 3)
        // Only first attempts are offered, and the retried test's first attempt is the one that failed.
        #expect(recording.observations.allSatisfy { $0.iteration == 1 })
        #expect(recording.observations.contains { $0.identifier == "DemoUnitTests/CalculatorTests/testFailsOnce()" && $0.seconds == 0.172 })
    }

    /// A shard with a genuine failure — not a retry — offers the duration store only its passed tests: the failed one's wait is what would inflate the test's history, and the two that finished normally beside it were not touched by whatever the failure was.
    @Test
    func aShardWithAFailureRecordsOnlyItsPassedTests() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSubtraction()")
        let third = try identifier("DemoUnitTests/CalculatorTests/testDivision()")

        let merged = ShardMerge.reconcile(plan: plan([[first, second, third]]), outcomes: [shard(outcomes(reading: [
            "Test testAddition() started.",
            "Test testAddition() passed after 0.010 seconds.",
            "Test testSubtraction() started.",
            "Test testSubtraction() passed after 0.020 seconds.",
            "Test testDivision() started.",
            "Test testDivision() failed after 30.000 seconds with 1 issue.",
        ]))])

        let recording = try #require(merged.recording(forShard: 1))

        #expect(!recording.retried)
        #expect(recording.missing == 0)
        #expect(recording.observations.count == 2)
        #expect(recording.observations.map(\.identifier).sorted() == [
            "DemoUnitTests/CalculatorTests/testAddition()", "DemoUnitTests/CalculatorTests/testSubtraction()",
        ])
    }

    /// A shard with a skip offers the duration store only the tests that actually ran: a skip's timing (XCTest can print one beside `skipped (… seconds)`) is not a run, and offering it would teach the store a wait no execution produced.
    @Test
    func aShardWithASkipRecordsOnlyItsRunTests() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSkipsWhenUnsupported()")

        let merged = ShardMerge.reconcile(plan: plan([[first, second]]), outcomes: [shard(outcomes(reading: [
            "Test Case '-[DemoUnitTests.CalculatorTests testAddition]' started.",
            "Test Case '-[DemoUnitTests.CalculatorTests testAddition]' passed (0.010 seconds).",
            "Test Case '-[DemoUnitTests.CalculatorTests testSkipsWhenUnsupported]' started.",
            "Test Case '-[DemoUnitTests.CalculatorTests testSkipsWhenUnsupported]' skipped (0.005 seconds).",
        ]))])

        let recording = try #require(merged.recording(forShard: 1))

        #expect(recording.observations.map(\.identifier) == ["DemoUnitTests/CalculatorTests/testAddition()"])
    }

    /// The tests that ran before a crash are counted as having run, the test that crashed is missing by name, and the run is not green over a log whose closing tally says `0 failures`.
    @Test
    func aCrashedTestIsMissingAndTheRelaunchesGreenTallyDoesNotCarryTheRun() throws {
        let tests = try demoUnitTests()
        let crashed = try identifier("DemoUnitTests/CalculatorTests/testMultiplyCrashesWhenTriggered()")

        let merged = try ShardMerge.reconcile(
            plan: plan([tests]),
            outcomes: [shard(outcomes("xcodebuild-crash-restart"), exitCode: 65)]
        )

        #expect(merged.counts == ShardReconciliation.Counts(expected: 9, ran: 8, passed: 7, failed: 0, skipped: 1, missing: 1, duplicated: 0))
        #expect(merged.missing == [ShardReconciliation.Missing(shard: 1, test: crashed)])
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 65)
    }

    /// Every shard exiting zero is not a pass: a test the plan named and no log reported is enough on its own, and the run exits 1 for it.
    @Test
    func aCleanExitOverAMissingTestIsStillNotGreen() throws {
        let tests = try demoUnitTests()

        let merged = try ShardMerge.reconcile(
            plan: plan([tests]),
            outcomes: [shard(outcomes("xcodebuild-crash-restart"), exitCode: 0)]
        )

        #expect(merged.counts.missing == 1)
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 1)
    }

    /// A shard ended at its wall-clock bound is named in the notes, while the counts read it exactly as they read any other shard that reported nothing.
    ///
    /// The merge is deliberately taught nothing about bounds: a test no log reported an ending for is already missing by the ordinary rule. What a count cannot carry is *why* — "missing" sends a reader to the crash reports, and these tests were never reached at all.
    @Test
    func aShardEndedAtItsBoundIsNamedInTheNotesAndCountedAsBefore() throws {
        let tests = try demoUnitTests()
        var ended = shard(RunTestOutcomes(), exitCode: 137, wallSeconds: 612)
        ended.timedOut = true

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [ended])

        #expect(merged.counts.missing == 9)
        #expect(!merged.isGreen)
        #expect(merged.notes.contains("shard 1 was ended after 612s with no result — its unreported tests are missing"))
    }

    /// The bound itself is named in the note only where a caller lowered it with `--shard-timeout` — the default floor needs no reminder, but a caller who moved it off the built-in ten minutes is told which reading fired.
    @Test
    func aLoweredShardTimeoutIsNamedInTheEndedNote() throws {
        let tests = try demoUnitTests()
        var ended = shard(RunTestOutcomes(), exitCode: 137, wallSeconds: 61)
        ended.timedOut = true

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [ended], shardTimeoutSeconds: 60)

        #expect(merged.notes.contains("shard 1 was ended after 61s with no result (bound 60s, set by --shard-timeout) — its unreported tests are missing"))
    }

    /// A shard that never started carries the reason in the notes: with no log to point at, the error's own sentence is the only thing the answer can print.
    @Test
    func aShardThatNeverStartedNamesWhyInTheNotes() throws {
        let tests = try demoUnitTests()
        var never = shard(RunTestOutcomes(), exitCode: 127, wallSeconds: 0, log: "")
        never.launchFailure = "could not start /usr/bin/env: No such file or directory"

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [never])

        #expect(merged.counts.missing == 9)
        #expect(merged.notes.contains("shard 1 never started — could not start /usr/bin/env: No such file or directory; its tests are missing"))
    }

    /// A result the plan has no shard for is counted, named and not green: a runner that hands back more than it was asked for is a defect, and silence over it is how a whole shard goes unaccounted for.
    @Test
    func aResultBeyondThePlansShardsIsNamedAndNotGreen() throws {
        let tests = try demoUnitTests()

        let merged = try ShardMerge.reconcile(
            plan: plan([tests]),
            outcomes: [shard(outcomes("xcodebuild-retry-iterations")), shard(RunTestOutcomes())]
        )

        // Everything the plan named was accounted for, so this note is the only thing holding the run back.
        #expect(merged.counts == ShardReconciliation.Counts(expected: 9, ran: 9, passed: 8, failed: 0, skipped: 1, missing: 0, duplicated: 0))
        #expect(merged.resultsOutsideThePlan == 1)
        #expect(merged.notes.contains("1 shard result was outside the plan and was not read"))
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 1)
    }

    /// A result beyond the plan's last shard that was itself ended at its bound is not just counted — its own reason is stated too, rather than dropped by a `zip` that stops at the plan's shorter length.
    @Test
    func aResultBeyondThePlansShardsThatTimedOutNamesItsOwnReasonToo() throws {
        let tests = try demoUnitTests()
        var extra = shard(RunTestOutcomes(), exitCode: 137, wallSeconds: 400)
        extra.timedOut = true

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [shard(RunTestOutcomes()), extra])

        #expect(merged.resultsOutsideThePlan == 1)
        #expect(merged.notes.contains("1 shard result was outside the plan and was not read"))
        #expect(merged.notes.contains("the shard result outside the plan was ended after 400s with no result — its unreported tests are missing"))
    }
}
