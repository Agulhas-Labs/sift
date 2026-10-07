//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the reconciliation: what the shards reported, against the tests the plan gave them.
///
/// The outcomes come from real captures wherever a capture carries the shape — a retried test, a crashed runner — because the whole point of reconciling is that the log is not to be believed, and a hand-written log is a transcript of what its author expected.
///
/// The suite carries `.temporaryDirectories` because what a reconciliation is *for* is partly what the duration store does with it, and that store is a file in a repository.
@Suite(.temporaryDirectories)
struct ShardMergeTests {
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

    /// A test that ends in a shard it was not given as well as in the one it was is duplicated, and the shards it ended in are both named.
    @Test
    func aTestEndingInTwoShardsIsDuplicated() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testDivision()")
        // Both shards ran the same tests — one `-only-testing:` argument too many is all it takes.
        let both = try outcomes("xcodebuild-retry-iterations")

        let merged = ShardMerge.reconcile(plan: plan([[first], [second]]), outcomes: [shard(both), shard(both)])

        #expect(merged.counts.duplicated == 2)
        #expect(merged.duplicated.map(\.test) == [first, second])
        #expect(merged.duplicated.allSatisfy { $0.shards == [1, 2] })
        #expect(merged.duplicated.allSatisfy { !$0.withinIteration })
        #expect(merged.counts.ran == 2)
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 1)
    }

    /// An ending under a quoted display name is stated, not spent: the one test the shard reported nothing for stays missing even where that ending is plausibly its own.
    ///
    /// The shard was given the very test the quoted literal most likely names, so this is the friendliest case the pairing had — and it is still refused, because nothing in a shard's log or its plan says the two belong together. Attributing it needs the declared literal, which only the inventory holds.
    @Test
    func aDisplayNamedEndingIsStatedRatherThanSpentOnTheTestItMightName() throws {
        let named = try identifier("WidgetTests/GridTests/theGridReflows()")
        let display = try identifier("WidgetTests/GridTests/readsItsOwnName()")

        let merged = try ShardMerge.reconcile(
            plan: plan([[named, display]]),
            outcomes: [shard(outcomes("swift-test-display-name"), exitCode: 1)]
        )

        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 1, passed: 0, failed: 1, skipped: 0, missing: 1, duplicated: 0))
        #expect(merged.missing == [ShardReconciliation.Missing(shard: 1, test: display)])
        #expect(merged.notes.contains { $0.hasPrefix("1 reported ending named no test the shard was given") })
        #expect(!merged.isGreen)
    }

    /// A quoted ending naming something the shard was never given does not cover up the test the shard *was* given and heard nothing from.
    ///
    /// This is the cover-up the count pairing made reachable: any unexpected quoted ending — a stray suite, another bundle, another run's log — spent on the test that crashed, and the run reading green over it. The ending is counted as unattributed and said out loud; the test stays missing and the run stays red.
    @Test
    func aQuotedEndingFromOutsideTheShardDoesNotCoverUpATestThatNeverRan() throws {
        let named = try identifier("WidgetTests/GridTests/theGridReflows()")
        let neverReported = try identifier("WidgetTests/ChartGridTests/theGridKeepsItsHeadings()")

        let merged = try ShardMerge.reconcile(
            plan: plan([[named, neverReported]]),
            outcomes: [shard(outcomes("swift-test-display-name"), exitCode: 1)]
        )

        #expect(merged.missing == [ShardReconciliation.Missing(shard: 1, test: neverReported)])
        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 1, passed: 0, failed: 1, skipped: 0, missing: 1, duplicated: 0))
        #expect(merged.notes.contains { $0.hasPrefix("1 reported ending named no test the shard was given") })
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 1)
    }

    /// A shard missing nothing is not told a test of its was reported missing, however many endings it could not attribute.
    ///
    /// The sentence explaining an unattributed ending explains a *missing* test by it. Over a shard that is missing none, it reports a state the run is not in — and it names Swift Testing's quoted form, which says nothing about an unattributed XCTest name from a bundle this shard was never given.
    @Test
    func aShardMissingNothingIsNotToldATestWasReportedMissing() throws {
        let named = try identifier("WidgetTests/GridTests/theGridReflows()")

        let merged = try ShardMerge.reconcile(
            plan: plan([[named]]),
            outcomes: [shard(outcomes("swift-test-display-name"), exitCode: 1)]
        )

        #expect(merged.missing.isEmpty)
        let attribution = try #require(merged.notes.first { $0.hasPrefix("1 reported ending named no test the shard was given") })
        #expect(!attribution.contains("reported missing"))
    }

    /// Where one function name is all the log gives and the shard expected two tests declaring it, a short count is missing without a name to give.
    @Test
    func aCountOnlyGroupThatCameUpShortIsMissingButUnnamed() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")

        let merged = try ShardMerge.reconcile(
            plan: plan([[first, second]]),
            outcomes: [shard(outcomes("xcodebuild-retry-iterations"))]
        )

        #expect(merged.counts.expected == 2)
        #expect(merged.counts.ran == 1)
        #expect(merged.counts.passed == 1)
        #expect(merged.counts.missing == 1)
        #expect(merged.missing.isEmpty)
        #expect(merged.shortfalls == [ShardReconciliation.Shortfall(shard: 1, function: "formatsUppercase", missing: 1, expected: 2)])
        #expect(merged.shortfalls[0].sentence == "1 of these 2 never reported")
        #expect(merged.notes.contains { $0.hasPrefix("Reconciled by count only — shard 1: formatsUppercase.") })
        #expect(!merged.isGreen)
    }

    /// An ending beyond what the group's tests can account for is counted as duplicated, not dropped.
    ///
    /// A shard given two tests declaring one name and ending that name three times has ended something twice, and the same log shape under a name the merge can tell apart is reported duplicated and reds the run. Dropping the surplus made the count-only group the one place a second ending was forgiven: three endings over two tests read `ran 3 · duplicated 0` and the run went green with a third test elsewhere that nothing accounts for.
    @Test
    func aCountOnlyGroupEndingItsNameMoreOftenThanItHasTestsCountsTheSurplusAsDuplicated() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")
        let elsewhere = try identifier("AlphaTests/MathSuite/formatsUppercase()")
        let ended = ["Test formatsUppercase() started.", "Test formatsUppercase() passed after 0.001 seconds."]

        let merged = ShardMerge.reconcile(
            plan: plan([[first, second], [elsewhere]]),
            outcomes: [shard(outcomes(reading: ended + ended + ended)), shard(outcomes(reading: ended))]
        )

        #expect(merged.counts == ShardReconciliation.Counts(expected: 3, ran: 3, passed: 3, failed: 0, skipped: 0, missing: 0, duplicated: 1))
        #expect(merged.duplicated.isEmpty)
        #expect(merged.notes.contains("shard 1: formatsUppercase: the run ended this name 1 time more than there are tests declaring it, which no retry explains, so the surplus is counted as duplicated with no name to give."))
        #expect(!merged.isGreen)
        #expect(merged.exitCode == 1)
    }

    /// A count-only group spends its endings worst first, so which of them the group is read on does not depend on the order the log printed them in.
    ///
    /// Nothing in the log says which test of the group an ending belonged to. Spending them in log order drops the failure whenever it arrived last, which makes the same run green or red on the ordering alone.
    @Test
    func aCountOnlyGroupSpendsItsEndingsWorstFirstWhateverOrderTheyArrivedIn() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")

        let merged = ShardMerge.reconcile(plan: plan([[first, second]]), outcomes: [shard(outcomes(reading: [
            "Test formatsUppercase() started.",
            "Test formatsUppercase() passed after 0.001 seconds.",
            "Test formatsUppercase() started.",
            "Test formatsUppercase() passed after 0.001 seconds.",
            "Test formatsUppercase() started.",
            "Test formatsUppercase() failed after 0.001 seconds with 1 issue.",
        ]))])

        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 2, passed: 1, failed: 1, skipped: 0, missing: 0, duplicated: 1))
        #expect(merged.failed.isEmpty)
        #expect(!merged.isGreen)
    }

    /// A count-only group a retry made green is counted as its retry: a later iteration's endings displace the worst standing before them, rather than the fullest iteration deciding the group.
    ///
    /// The first pass over a group of two always prints more endings than the retry of the one that failed, so reading the fullest iteration reported every retried group as the failure it started as — the opposite of the rule the design states for every other reading, that a retry across iterations is one test with attempts and its last attempt is its outcome.
    @Test
    func aCountOnlyGroupARetryMadeGreenIsCountedAsItsRetry() throws {
        let first = try identifier("AlphaTests/CalculatorTests/testAddition()")
        let second = try identifier("BetaTests/CalculatorTests/testAddition()")

        let merged = ShardMerge.reconcile(plan: plan([[first, second]]), outcomes: [shard(outcomes(reading: [
            "Test Case '-[CalculatorTests testAddition]' started (Iteration 1 of 2).",
            "Test Case '-[CalculatorTests testAddition]' failed (0.100 seconds).",
            "Test Case '-[CalculatorTests testAddition]' started (Iteration 1 of 2).",
            "Test Case '-[CalculatorTests testAddition]' passed (0.100 seconds).",
            "Test Case '-[CalculatorTests testAddition]' started (Iteration 2 of 2).",
            "Test Case '-[CalculatorTests testAddition]' passed (0.100 seconds).",
        ]))])

        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(merged.isGreen)
    }

    /// The counts are spelled the way the design names them, in that order.
    @Test
    func theCountsLineNamesEveryFieldInOrder() throws {
        let tests = try demoUnitTests()

        let merged = try ShardMerge.reconcile(plan: plan([tests]), outcomes: [shard(outcomes("xcodebuild-crash-restart"), exitCode: 65)])

        #expect(merged.counts.line == "expected 9 · ran 8 · passed 7 · failed 0 · skipped 1 · missing 1 · duplicated 0")
    }

    /// A test its own shard reported nothing for and another shard ended is still missing, and the note names the shard that ended it rather than leaving the reader at the crash reports.
    @Test
    func aTestThatEndedOnlyInAnotherShardIsMissingWithThatShardNamed() throws {
        let owned = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let other = try identifier("DemoUnitTests/CalculatorTests/testDivision()")
        // Shard 1 reported nothing at all; shard 2's log ends both tests, one of which it was never given.
        let both = try outcomes("xcodebuild-retry-iterations")

        let merged = ShardMerge.reconcile(plan: plan([[owned], [other]]), outcomes: [shard(RunTestOutcomes()), shard(both)])

        #expect(merged.counts.missing == 1)
        #expect(merged.missing == [ShardReconciliation.Missing(shard: 1, test: owned)])
        #expect(!merged.isGreen)
        #expect(merged.notes.contains("DemoUnitTests/CalculatorTests/testAddition() reported nothing in shard 1, which was given it, but ended in shard 2 — it ran in the wrong shard rather than not at all"))
    }

    /// A failure naming a test that started and never ended is kept: the test is missing rather than failed, so this line is the only sentence the answer has about why it is missing.
    @Test
    func aFailureNamingATestThatNeverEndedIsStillListed() throws {
        let tests = try demoUnitTests()
        let crashed = RunTestFailure(name: "-[DemoUnitTests.CalculatorTests testMultiplyCrashesWhenTriggered]", location: "CalculatorTests.swift:28", message: "Fatal error: boom")
        let outcome = try ShardOutcome(outcomes: outcomes("xcodebuild-crash-restart"), exitCode: 65, wallSeconds: 30, logPath: "/tmp/shard.log", failures: [crashed])

        let merged = ShardMerge.reconcile(plan: plan([tests]), outcomes: [outcome])

        #expect(merged.counts.missing == 1)
        #expect(merged.failures.map(\.name) == ["-[DemoUnitTests.CalculatorTests testMultiplyCrashesWhenTriggered]"])
    }

    /// A failure naming a test only a count-only group could claim is kept: no such test ends under an identity the tally holds, so dropping it would leave a failure count standing over nothing.
    @Test
    func aFailureNamingACountOnlyTestIsStillListed() throws {
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")
        let failure = RunTestFailure(name: "formatsUppercase()", location: "MathSuite.swift:12", message: "Expectation failed: 1 == 2")
        let outcome = try ShardOutcome(outcomes: outcomes("xcodebuild-retry-iterations"), exitCode: 1, wallSeconds: 30, logPath: "/tmp/shard.log", failures: [failure])

        let merged = ShardMerge.reconcile(plan: plan([[first, second]]), outcomes: [outcome])

        #expect(merged.failures.map(\.name) == ["formatsUppercase()"])
    }

    /// A shard of a target whose module name is not its target name is reconciled as having run: the enumeration's spelling and the log's differ by the substitution Xcode made, and nothing in the log says so.
    @Test
    func aTargetLoggedUnderItsModuleNameRanRatherThanWentMissing() throws {
        let tests = try ["testCountsUp", "testCountsDown"].map {
            try identifier("Demo Spaced Tests/SpacedTests/\($0)()")
        }

        let merged = try ShardMerge.reconcile(
            plan: plan([tests]),
            outcomes: [shard(outcomes("xcodebuild-test-underscored-module"))]
        )

        #expect(merged.counts.missing == 0)
        #expect(merged.counts.ran == 2)
        #expect(merged.isGreen)
    }

    /// A test that declares its own quoted name is counted by the ending it logged under, where the plan carries the literal its declaration wrote.
    ///
    /// Each consequence of reporting it missing is asserted separately, because they are separate costs and the third is the one nobody sees: the test is not missing, the run exits 0, and the shard's recording still reaches the duration store — a recording the store drops *whole* where anything is missing, so a shard holding one display-named test would otherwise never contribute a duration again, and every test beside it be charged an estimate for ever.
    @Test
    func aDisplayNamedEndingIsCountedOntoTheTestTheInventorySaysDeclaresIt() throws {
        let sibling = try identifier("WidgetTests/GridTests/theGridReflows()")
        let named = try identifier("WidgetTests/GridTests/readsItsOwnName()")

        let merged = ShardMerge.reconcile(
            plan: plan([[sibling, named]], displayNames: ["\"The Test Reads Its Own Name\"": [named]]),
            outcomes: [shard(outcomes(reading: [
                "Test theGridReflows() started.",
                "Test \"The Test Reads Its Own Name\" started.",
                "Test theGridReflows() passed after 0.400 seconds.",
                "Test \"The Test Reads Its Own Name\" passed after 0.200 seconds.",
            ]))]
        )

        #expect(merged.missing.isEmpty)
        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(merged.isGreen)
        #expect(merged.exitCode == 0)
        #expect(!merged.notes.contains { $0.hasPrefix("1 reported ending named no test the shard was given") })

        var durations = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("shard-display-names"))
        let recording = try #require(merged.recording(forShard: 1))
        durations.record(recording)
        #expect(durations.median(for: sibling.enumerated) == 0.4)
        #expect(durations.median(for: named.enumerated) == 0.2)
    }

    /// A quoted ending whose literal belongs to a test of another shard is still not spent on a test this one heard nothing from.
    ///
    /// The literals reach the merge as a whole run's worth, not a shard's, so this is the cover-up the join has to keep refusing: the candidate is narrowed to the tests this shard was given and is still waiting on, and a literal that names none of them leaves the test missing. The ending is the test that declares the literal running in the wrong shard, so it is that test's, and a test that also ended in its own shard is duplicated.
    @Test
    func aDisplayNameDeclaredByAnotherShardsTestDoesNotCoverUpATestThatNeverRan() throws {
        let elsewhere = try identifier("WidgetTests/ChartGridTests/readsItsOwnName()")
        let neverReported = try identifier("WidgetTests/GridTests/theGridReflows()")

        let merged = ShardMerge.reconcile(
            plan: plan(
                [[neverReported], [elsewhere]],
                displayNames: ["\"The Test Reads Its Own Name\"": [elsewhere]]
            ),
            outcomes: [
                shard(outcomes(reading: [
                    "Test \"The Test Reads Its Own Name\" started.",
                    "Test \"The Test Reads Its Own Name\" passed after 0.200 seconds.",
                ]), exitCode: 0),
                shard(outcomes(reading: [
                    "Test readsItsOwnName() started.",
                    "Test readsItsOwnName() passed after 0.200 seconds.",
                ])),
            ]
        )

        #expect(merged.missing == [ShardReconciliation.Missing(shard: 1, test: neverReported)])
        #expect(merged.duplicated == [ShardReconciliation.Duplication(test: elsewhere, shards: [1, 2], withinIteration: false)])
        #expect(!merged.notes.contains { $0.hasPrefix("1 reported ending named no test the shard was given") })
        #expect(!merged.isGreen)
    }

    /// Two tests one shard was given that declare the same literal, and the plan's record of it.
    private func sharedLiteralPlan() throws -> ShardPlan {
        let first = try identifier("WidgetTests/GridTests/first()")
        let second = try identifier("WidgetTests/ChartGridTests/second()")
        return plan([[first, second]], displayNames: ["\"Alpha\"": [first, second]])
    }

    /// A literal two of the shard's tests share is reconciled by count, as the unsharded path does it: two endings for a group of two is both run, and nothing is missing.
    @Test
    func twoTestsSharingALiteralThatBothEndedAreGreenInAShard() throws {
        let merged = try ShardMerge.reconcile(
            plan: sharedLiteralPlan(),
            outcomes: [shard(outcomes(reading: [
                "Test \"Alpha\" started.",
                "Test \"Alpha\" passed after 0.100 seconds.",
                "Test \"Alpha\" started.",
                "Test \"Alpha\" passed after 0.100 seconds.",
            ]))]
        )

        #expect(merged.missing.isEmpty)
        #expect(merged.shortfalls.isEmpty)
        #expect(merged.counts == ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(merged.notes.contains { $0.hasPrefix("Reconciled by count only — shard 1: \"Alpha\".") })
        #expect(merged.isGreen)
    }

    /// One ending for a group of two is a shortfall with no name to give, and the run stays red.
    @Test
    func twoTestsSharingALiteralWithOneEndingAreAShortfallInAShard() throws {
        let merged = try ShardMerge.reconcile(
            plan: sharedLiteralPlan(),
            outcomes: [shard(outcomes(reading: [
                "Test \"Alpha\" started.",
                "Test \"Alpha\" passed after 0.100 seconds.",
            ]))]
        )

        #expect(merged.missing.isEmpty)
        #expect(merged.shortfalls == [ShardReconciliation.Shortfall(shard: 1, function: "\"Alpha\"", missing: 1, expected: 2)])
        #expect(merged.counts.missing == 1)
        #expect(!merged.isGreen)
    }
}
