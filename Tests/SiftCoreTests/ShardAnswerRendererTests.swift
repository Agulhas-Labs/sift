//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the answer: what a caller reads for a sharded run, built from a reconciliation and the plan it reconciled against.
///
/// Most reconciliations here are built by hand rather than through ``ShardMerge``, because the renderer's own contract is what each field prints, and a hand-built value pins that without depending on how a real log happens to parse.
struct ShardAnswerRendererTests {
    private func identifier(_ enumerated: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> TestIdentifier {
        try #require(TestIdentifier(enumerated: enumerated), sourceLocation: sourceLocation)
    }

    private func plan(_ shards: [[TestIdentifier]]) -> ShardPlan {
        ShardPlan(
            shards: shards.enumerated().map { index, tests in
                ShardPlan.Shard(index: index + 1, tests: tests, predictedSeconds: 20 + Double(tests.count))
            },
            requestedShards: shards.count,
            overheadSeconds: 20,
            estimatedTests: 0,
            estimatedSeconds: 1,
            lowering: nil
        )
    }

    private func shard(
        index: Int = 1,
        testCount: Int,
        iterations: Int = 1,
        wallSeconds: Double = 5,
        executionSeconds: Double = 3,
        predictedSeconds: Double = 6,
        exitCode: Int32 = 0,
        logPath: String = "/tmp/shard.log"
    ) -> ShardReconciliation.Shard {
        ShardReconciliation.Shard(
            index: index, testCount: testCount, iterations: iterations, wallSeconds: wallSeconds,
            executionSeconds: executionSeconds, predictedSeconds: predictedSeconds, exitCode: exitCode,
            logPath: logPath, recording: TestDurationStore.Recording(observations: [], retried: false, missing: 0)
        )
    }

    /// A green run names what it covered — nothing about the shard line, the counts or the slowest listing owes anything more than what actually ran.
    @Test
    func aGreenRunReadsAsOneExactAnswer() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSubtraction()")
        let counts = ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 2)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [
                ShardReconciliation.Timing(shard: 1, test: first, seconds: 2),
                ShardReconciliation.Timing(shard: 1, test: second, seconds: 1),
            ], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer().render(reconciliation, plan: plan([[first, second]]))

        #expect(rendered == """
        ✔ sift test — 2 tests passed across 1 shard
          expected 2 · ran 2 · passed 2 · failed 0 · skipped 0 · missing 0 · duplicated 0

        shard 1: 2 tests · wall 5s (predicted 6s) · tests 3s · iterations 1 · exit 0 · /tmp/shard.log

        slowest:
          2s  DemoUnitTests/CalculatorTests/testAddition()
          1s  DemoUnitTests/CalculatorTests/testSubtraction()
        """)
    }

    /// Failures with a shape to group them by go through ``RunFailureShape``, which is what earns the classification line and the resolved locations above the bare names.
    @Test
    func failuresWithDetailRenderThroughTheShape() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSubtraction()")
        let counts = ShardReconciliation.Counts(expected: 2, ran: 2, passed: 0, failed: 2, skipped: 0, missing: 0, duplicated: 0)
        let failures = [
            RunTestFailure(name: first.enumerated, location: "CalculatorTests.swift:10", message: "XCTAssertEqual failed: (1) is not equal to (2)"),
            RunTestFailure(name: second.enumerated, location: "CalculatorTests.swift:20", message: "XCTAssertEqual failed: (1) is not equal to (2)"),
        ]
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 2, exitCode: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [first, second], timings: [], failures: failures, notes: []
        )

        let rendered = ShardAnswerRenderer().render(reconciliation, plan: plan([[first, second]]))

        #expect(rendered.contains("2 failures · 1 signature · 1 file · changed files unknown — the working tree was not consulted"))
        #expect(rendered.contains("  DemoUnitTests/CalculatorTests/testAddition() — CalculatorTests.swift:10"))
        #expect(rendered.contains("    XCTAssertEqual failed: (1) is not equal to (2)"))
    }

    /// Without a shape to group them by a failure is just its own identifier, and with no `rerunCommand` the re-run line offers no whole command to claim as runnable.
    @Test
    func failuresWithoutDetailListJustTheirIdentifiers() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 0, failed: 1, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1, exitCode: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [test], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer().render(reconciliation, plan: plan([[test]]))

        #expect(rendered == """
        ✘ sift test — 1 failed — exit 1
          expected 1 · ran 1 · passed 0 · failed 1 · skipped 0 · missing 0 · duplicated 0

        DemoUnitTests/CalculatorTests/testAddition()

        shard 1: 1 tests · wall 5s (predicted 6s) · tests 3s · iterations 1 · exit 1 · /tmp/shard.log

        re-run just these with --shards 1:
          --only 'DemoUnitTests/CalculatorTests/testAddition()'
        """)
    }

    /// A `rerunCommand` turns the re-run line into the whole command a reader can paste and run: the caller's own flags, `--shards 1` so it never re-shards, and `--only` for each failure — never a `…` the reader has to reconstruct.
    @Test
    func aRerunCommandMakesTheReRunLineTheWholeCommand() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSubtraction()")
        let counts = ShardReconciliation.Counts(expected: 2, ran: 2, passed: 0, failed: 2, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 2, exitCode: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [first, second], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer(rerunCommand: "sift test --scheme TestDemo --device 'iPhone 17'", rerunSuffix: " -- -derivedDataPath .derived")
            .render(reconciliation, plan: plan([[first, second]]))

        #expect(rendered.contains("re-run just these, serially:"))
        #expect(rendered.contains(
            "  sift test --scheme TestDemo --device 'iPhone 17' --shards 1 --only 'DemoUnitTests/CalculatorTests/testAddition()' --only 'DemoUnitTests/CalculatorTests/testSubtraction()' -- -derivedDataPath .derived"
        ))
    }

    /// A missing test is named where it can be, and a shortfall only by how many of its group never reported — and the crash reports written during a run that has something missing sit under the same heading.
    @Test
    func missingAndShortfallsListWithTheirCrashReports() throws {
        let named = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let first = try identifier("DemoUnitTests/MathSuite/formatsUppercase()")
        let second = try identifier("DemoUnitTests/FormattingSuite/formatsUppercase()")
        let counts = ShardReconciliation.Counts(expected: 3, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 2, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 3)],
            missing: [ShardReconciliation.Missing(shard: 1, test: named)],
            shortfalls: [ShardReconciliation.Shortfall(shard: 1, function: "formatsUppercase", missing: 1, expected: 2)],
            duplicated: [], failed: [], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer(crashReports: ["/tmp/crash1.ips"]).render(reconciliation, plan: plan([[named, first, second]]))

        #expect(rendered.contains("""
        missing:
          shard 1: DemoUnitTests/CalculatorTests/testAddition()
          1 of these 2 never reported
        crash reports written during the run:
          /tmp/crash1.ips
        """))
    }

    /// A crash report is only ever evidence for something the run lost — one supplied over a run that lost nothing has nothing to attach to and prints nothing.
    @Test
    func aCrashReportOverNothingMissingPrintsNothing() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer(crashReports: ["/tmp/crash1.ips"]).render(reconciliation, plan: plan([[test]]))

        #expect(!rendered.contains("crash"))
        #expect(!rendered.contains("missing:"))
    }

    /// A test that ended twice names the shards it ended in, unless both endings landed in the one iteration, which is the reading a retry is most easily mistaken for.
    @Test
    func duplicatedTestsNameWhereTheyEndedOrThatItWasWithinOneIteration() throws {
        let first = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let second = try identifier("DemoUnitTests/CalculatorTests/testSubtraction()")
        let counts = ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 2)
        let duplicated = [
            ShardReconciliation.Duplication(test: first, shards: [1, 2], withinIteration: false),
            ShardReconciliation.Duplication(test: second, shards: [1], withinIteration: true),
        ]
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1), shard(index: 2, testCount: 1, logPath: "/tmp/shard2.log")],
            missing: [], shortfalls: [], duplicated: duplicated, failed: [], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer().render(reconciliation, plan: plan([[first], [second]]))

        #expect(rendered.contains("DemoUnitTests/CalculatorTests/testAddition() ended in shards 1, 2"))
        #expect(rendered.contains("DemoUnitTests/CalculatorTests/testSubtraction() ended twice within one iteration"))
    }

    /// A shard that spent more than twice its tests' own time launching, starting a session or loading a bundle says so, because that is then the thing to fix rather than the tests.
    @Test
    func aShardWhoseWallClockDwarfsItsTestsCarriesTheRemark() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1, wallSeconds: 20, executionSeconds: 2)],
            missing: [], shortfalls: [], duplicated: [], failed: [], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer().render(reconciliation, plan: plan([[test]]))

        #expect(rendered.contains("wall clock is more than twice the tests' own time — launch, session start and bundle load are outside every test's own time"))
    }

    /// A lowered plan and an estimated one each owe the answer a sentence, and both print ahead of the reconciliation's own notes and the trailing device line — the last thing this answer says is a fact about the device, not about the plan.
    @Test
    func loweringAndEstimateNotesPrecedeReconciliationNotesAndTheDeviceLineIsLast() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [], failures: [], notes: ["a note from the reconciliation"]
        )
        let lowered = ShardPlan(
            shards: [ShardPlan.Shard(index: 1, tests: [test], predictedSeconds: 6)],
            requestedShards: 4, overheadSeconds: 20, estimatedTests: 1, estimatedSeconds: 1,
            lowering: ShardPlan.Lowering(requested: 4, considered: 4, used: 1, consideredMakespan: 6)
        )

        let rendered = ShardAnswerRenderer(
            devicesLine: "device iPhone 16 (booted) reset accessibility",
            sweepLines: ["swept 2 stale simulators"]
        ).render(reconciliation, plan: lowered)

        #expect(rendered == """
        ✔ sift test — 1 tests passed across 1 shard
          expected 1 · ran 1 · passed 1 · failed 0 · skipped 0 · missing 0 · duplicated 0

        shard 1: 1 tests · wall 5s (predicted 6s) · tests 3s · iterations 1 · exit 0 · /tmp/shard.log

        Planned 1 shard rather than 4: at 4 the slowest shard is predicted at 6s against 6s here, because every shard pays 20s of launch, session start and bundle load before its first test runs.
        No test in this plan has a recorded duration, so all 1 were charged 1s and the partition is even by count alone.
        a note from the reconciliation

        swept 2 stale simulators
        device iPhone 16 (booted) reset accessibility
        """)
    }

    /// The run's one timing line follows the shard lines, its phases in the order the run passed through them.
    @Test
    func thePhaseLineFollowsTheShardLinesInTheOrderTheRunPassedThroughThem() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [], failures: [], notes: []
        )
        let phases = ShardPhases(build: 12, enumerate: 7, devicesReady: 30, shards: 200, teardown: 6)

        let rendered = ShardAnswerRenderer(phases: phases).render(reconciliation, plan: plan([[test]]))

        #expect(rendered.hasSuffix("""

        shard 1: 1 tests · wall 5s (predicted 6s) · tests 3s · iterations 1 · exit 0 · /tmp/shard.log
        build 12s · enumerate 7s · devices ready +30s · shards 200s · teardown 6s
        """))
        #expect(ShardPhases(build: 30, enumerate: 7, devicesReady: 0, shards: 90.5, teardown: 4).line == "build 30s · enumerate 7s · devices ready +0s · shards 90.5s · teardown 4s")
    }

    /// A shard that exits non-zero with every count clean — a crash after the last ending — still gets a headline that says so, in the package answer and the other alike, rather than nothing between the dashes.
    @Test(arguments: [false, true])
    func aNonZeroExitOverCleanCountsNamesTheShardInTheHeadline(swiftPackage: Bool) throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1, exitCode: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [], failures: [], notes: []
        )

        let rendered = ShardAnswerRenderer(swiftPackage: swiftPackage).render(reconciliation, plan: plan([[test]]))

        #expect(rendered.hasPrefix("""
        ✘ sift test — shard 1 exited non-zero with no test failed or missing — its log is on its shard line below — exit 1
          expected 1 · ran 1 · passed 1 · failed 0 · skipped 0 · missing 0 · duplicated 0

        shard 1: 1 tests · wall 5s (predicted 6s) · tests 3s · iterations 1 · exit 1 · /tmp/shard.log
        """))
    }

    /// A shard result the plan has no shard for is a reason the run is not green, so the headline names it rather than printing nothing between the dashes.
    @Test
    func aResultOutsideThePlanIsNamedInTheHeadline() throws {
        let test = try identifier("DemoUnitTests/CalculatorTests/testAddition()")
        let counts = ShardReconciliation.Counts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard(testCount: 1)], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [], failures: [], notes: [], resultsOutsideThePlan: 1
        )

        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan([[test]]))

        #expect(rendered.hasPrefix("✘ sift test — 1 shard result outside the plan — exit 1\n"))
    }
}
