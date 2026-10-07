//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the static partition: which tests go in which shard, how many shards there are, and what the plan says about both.
struct ShardPlannerTests {
    private func identifier(_ enumerated: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> TestIdentifier {
        try #require(TestIdentifier(enumerated: enumerated), sourceLocation: sourceLocation)
    }

    /// Ten tests named `t1…t10`, so a partition can be read by name.
    private func identifiers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> [TestIdentifier] {
        try (1 ... count).map { try identifier("DemoUnitTests/CalculatorTests/t\($0)()", sourceLocation: sourceLocation) }
    }

    private func lookup(_ seconds: [TestIdentifier: Double]) -> (TestIdentifier) -> Double? {
        { seconds[$0] }
    }

    /// The longest test goes first and every one after it joins the shard carrying the least, which is what keeps the two ends of a partition together.
    @Test
    func theLongestTestGoesFirstAndTheRestFillTheEmptiestShard() throws {
        let tests = try identifiers(4)
        let seconds = [tests[0]: 100.0, tests[1]: 90.0, tests[2]: 80.0, tests[3]: 70.0]

        let plan = ShardPlanner.plan(tests: tests, shards: 2, duration: lookup(seconds))

        #expect(plan.shards.count == 2)
        #expect(plan.shards[0].tests == [tests[0], tests[3]])
        #expect(plan.shards[1].tests == [tests[1], tests[2]])
        #expect(plan.shards[0].predictedSeconds == 190)
        #expect(plan.predictedMakespan == 190)
        #expect(plan.lowering == nil)
    }

    /// The same tests in any order plan the same way: the order is the durations' and, where those tie, the identifiers' — never the caller's.
    @Test
    func aShuffledInputPlansIdentically() throws {
        let tests = try identifiers(8)
        // Four pairs of equal durations, so every tie has to be settled by identifier for the two plans to agree.
        let seconds = Dictionary(uniqueKeysWithValues: tests.enumerated().map { index, test in (test, Double(index / 2 + 1) * 10) })

        let plan = ShardPlanner.plan(tests: tests, shards: 3, duration: lookup(seconds))
        let shuffled = ShardPlanner.plan(tests: tests.reversed(), shards: 3, duration: lookup(seconds))

        #expect(plan == shuffled)
        #expect(plan.shards.count == 3)
        #expect(plan.shards.flatMap(\.tests).count == 8)
    }

    /// Three tests worth a second between them are one shard's work, and the plan says what the other two shards would have cost.
    @Test
    func aSplitThatWouldNotPayForItselfIsNotMade() throws {
        let tests = try identifiers(3)
        let seconds = Dictionary(uniqueKeysWithValues: tests.map { ($0, 0.3) })

        let plan = ShardPlanner.plan(tests: tests, shards: 3, duration: lookup(seconds))

        #expect(plan.shards.count == 1)
        #expect(plan.shards[0].tests.count == 3)
        #expect(plan.lowering == ShardPlan.Lowering(requested: 3, considered: 3, used: 1, consideredMakespan: 20.3))
        #expect(plan.loweringNote == "Planned 1 shard rather than 3: at 3 the slowest shard is predicted at 20.3s against 20.9s here, because every shard pays 20s of launch, session start and bundle load before its first test runs.")
    }

    /// A shard the partition cannot actually use is not planned: four equal tests finish no sooner on three shards than on two, so the third is not asked for.
    @Test
    func aShardThePartitionCannotUseIsNotPlanned() throws {
        let tests = try identifiers(4)
        let seconds = Dictionary(uniqueKeysWithValues: tests.map { ($0, 30.0) })

        let plan = ShardPlanner.plan(tests: tests, shards: 3, duration: lookup(seconds))

        #expect(plan.shards.count == 2)
        #expect(plan.predictedMakespan == 80)
        #expect(plan.lowering?.used == 2)
        #expect(plan.lowering?.consideredMakespan == 80)
    }

    /// A test nobody has timed is charged the median of those that have been, and the plan says how many were charged that way.
    @Test
    func aTestWithNoHistoryIsChargedTheMedianOfThoseThatHaveOne() throws {
        let tests = try identifiers(4)
        let seconds = [tests[0]: 1.0, tests[1]: 3.0, tests[2]: 5.0]

        let plan = ShardPlanner.plan(tests: tests, shards: 1, duration: lookup(seconds))

        #expect(plan.estimatedTests == 1)
        #expect(plan.estimatedSeconds == 3)
        #expect(plan.shards[0].predictedSeconds == 32)
        // The only target in this plan, so its own median and the plan's overall median are the same
        // computation — the charge came from ``knownByTarget``, so it is named as the target's.
        #expect(plan.estimateNote == "1 of 4 tests have no recorded duration and were charged 3s, the median of their target's timed tests.")
    }

    /// An untimed test is charged what its own target's tests cost, and a count asked for is kept while any test is an estimate.
    @Test
    func untimedTestsTakeTheirOwnTargetsMedianAndNeverLowerTheCount() throws {
        let unit = try identifiers(6)
        let timedUI = try identifier("DemoUITests/ItemListUITests/testItemListAppears()")
        let untimedUI = try (1 ... 5).map { try identifier("DemoUITests/ItemListUITests/u\($0)()") }
        var seconds = Dictionary(uniqueKeysWithValues: unit.map { ($0, 0.001) })
        seconds[timedUI] = 12

        let plan = ShardPlanner.plan(tests: unit + [timedUI] + untimedUI, shards: 3, duration: lookup(seconds))

        #expect(plan.shards.count == 3)
        #expect(plan.lowering == nil)
        #expect(plan.shards.map { $0.tests.count(where: { $0.target == "DemoUITests" }) } == [2, 2, 2])
        #expect(plan.estimateNote == "5 of 12 tests have no recorded duration and were charged 12s, the median of their target's timed tests. The shard count asked for was kept: a split is only judged not to pay for itself on measurements.")
    }

    /// Untimed tests in different targets are named by target when their charges differ, rather than folded into one figure that belongs to neither.
    @Test
    func differingTargetChargesAreNamedInTheEstimateNote() throws {
        let alpha1 = try identifier("AlphaTests/FooTests/alpha1()")
        let alpha2 = try identifier("AlphaTests/FooTests/alpha2()")
        let alpha3 = try identifier("AlphaTests/FooTests/alpha3()")
        let gizmo1 = try identifier("GizmoTests/FooTests/gizmo1()")
        let gizmo2 = try identifier("GizmoTests/FooTests/gizmo2()")
        let seconds = [alpha1: 10.0, alpha2: 20.0, gizmo1: 100.0]

        let plan = ShardPlanner.plan(tests: [alpha1, alpha2, alpha3, gizmo1, gizmo2], shards: 1, duration: lookup(seconds))

        #expect(plan.estimateNote == "2 of 5 tests have no recorded duration and were charged their own target's median where it has one (AlphaTests 15s, GizmoTests 100s), else the plan's.")
    }

    /// A target's own median can equal the plan's overall median by coincidence — the source is carried beside the charge rather than guessed by comparing the two numbers, so this is still named as the target's.
    @Test
    func aTargetsMedianThatCoincidentallyMatchesThePlansIsStillNamedAsTheTargets() throws {
        let untimed = try identifier("AlphaTests/FooTests/untimed()")
        let alpha1 = try identifier("AlphaTests/FooTests/alpha1()")
        let alpha2 = try identifier("AlphaTests/FooTests/alpha2()")
        let beta1 = try identifier("BetaTests/FooTests/beta1()")
        let beta2 = try identifier("BetaTests/FooTests/beta2()")
        let beta3 = try identifier("BetaTests/FooTests/beta3()")
        // AlphaTests' own median is (10 + 30) / 2 = 20, and the plan's overall median over all five timed
        // tests — 10, 20, 20, 20, 30 — is also 20: the same number for two different reasons.
        let seconds = [alpha1: 10.0, alpha2: 30.0, beta1: 20.0, beta2: 20.0, beta3: 20.0]

        let plan = ShardPlanner.plan(tests: [untimed, alpha1, alpha2, beta1, beta2, beta3], shards: 1, duration: lookup(seconds))

        #expect(plan.estimatedSeconds == 20)
        #expect(plan.estimateNote == "1 of 6 tests have no recorded duration and were charged 20s, the median of their target's timed tests.")
    }

    /// Two targets charged the identical seconds from different sources — one its own median, the other the plan's, by coincidence — word the note the same way on every plan, chosen by the target named first rather than by whichever the dictionary happened to iterate first.
    @Test
    func theEstimateNoteNamesTheSameSourceEveryRunWhenChargesTieAcrossTargets() throws {
        let untimedAlpha = try identifier("AlphaTests/FooTests/untimed()")
        let alpha1 = try identifier("AlphaTests/FooTests/alpha1()")
        let alpha2 = try identifier("AlphaTests/FooTests/alpha2()")
        let beta1 = try identifier("BetaTests/FooTests/beta1()")
        let beta2 = try identifier("BetaTests/FooTests/beta2()")
        let beta3 = try identifier("BetaTests/FooTests/beta3()")
        let untimedGizmo = try identifier("GizmoTests/FooTests/untimed()")
        // AlphaTests' own median is 20 (targetMedian); GizmoTests has no timed test of its own, so its
        // untimed test is charged the plan's overall median, also 20 (planMedian) — the same seconds, two
        // different sources, tied in a `Dictionary` whose iteration order is not fixed.
        let seconds = [alpha1: 10.0, alpha2: 30.0, beta1: 20.0, beta2: 20.0, beta3: 20.0]
        let tests = [untimedAlpha, alpha1, alpha2, beta1, beta2, beta3, untimedGizmo]

        for _ in 0 ..< 5 {
            let plan = ShardPlanner.plan(tests: tests, shards: 1, duration: lookup(seconds))
            #expect(plan.estimateNote == "2 of 7 tests have no recorded duration and were charged 20s, the median of their target's timed tests.")
        }
    }

    /// Where nothing has been timed at all every test is charged a second, which partitions by count and says so.
    @Test
    func aPlanWithNoHistoryAtAllPartitionsByCount() throws {
        let tests = try identifiers(6)

        let plan = ShardPlanner.plan(tests: tests, shards: 2, overheadSeconds: 0, duration: { _ in nil })

        #expect(plan.estimatedSeconds == 1)
        #expect(plan.shards.map(\.tests.count) == [3, 3])
        #expect(plan.estimateNote == "No test in this plan has a recorded duration, so all 6 were charged 1s and the partition is even by count alone.")
    }

    /// More shards than tests is the tests' count, and the plan says the extra shards had no work rather than reporting empty ones.
    @Test
    func theShardCountIsClampedToTheTestsThereAre() throws {
        let tests = try identifiers(2)
        let seconds = Dictionary(uniqueKeysWithValues: tests.map { ($0, 600.0) })

        let plan = ShardPlanner.plan(tests: tests, shards: 5, duration: lookup(seconds))

        #expect(plan.shards.count == 2)
        #expect(plan.requestedShards == 5)
        #expect(plan.lowering?.considered == 2)
        #expect(plan.loweringNote == "5 shards asked for over 2 tests, so 2 is the most there was work for.")
    }

    /// One shard splits nothing and answers in the same shape.
    @Test
    func oneShardSplitsNothing() throws {
        let tests = try identifiers(5)

        let plan = ShardPlanner.plan(tests: tests, shards: 1, duration: { _ in 4 })

        #expect(plan.shards.count == 1)
        #expect(plan.shards[0].tests.count == 5)
        #expect(plan.shards[0].index == 1)
        #expect(plan.shards[0].predictedSeconds == 40)
        #expect(plan.lowering == nil)
    }

    /// The default is the smallest of half the performance cores, a quarter of the memory and three — and never less than one.
    @Test
    func theDefaultShardCountIsBoundedByTheMachineAndByThree() {
        #expect(ShardPlanner.defaultShardCount(performanceCores: 12, memoryGB: 64) == 3)
        #expect(ShardPlanner.defaultShardCount(performanceCores: 4, memoryGB: 64) == 2)
        #expect(ShardPlanner.defaultShardCount(performanceCores: 12, memoryGB: 8) == 2)
        #expect(ShardPlanner.defaultShardCount(performanceCores: 1, memoryGB: 2) == 1)
    }

    /// A count far beyond what any host could run is clamped to ``ShardPlanner/maximumShards`` before it is ever packed, and the plan says that clamp is why.
    @Test
    func aRequestFarAboveTheMaximumIsClampedBeforePacking() throws {
        let tests = try identifiers(20)
        let seconds = Dictionary(uniqueKeysWithValues: tests.map { ($0, 30.0) })

        let plan = ShardPlanner.plan(tests: tests, shards: 5000, duration: lookup(seconds))

        #expect(plan.shards.count <= ShardPlanner.maximumShards)
        #expect(plan.lowering?.considered == ShardPlanner.maximumShards)
        #expect(plan.loweringNote?.hasPrefix("5000 shards asked for; \(ShardPlanner.maximumShards) is the most sift will ever plan onto, since every shard is a booted simulator.") == true)
    }
}
