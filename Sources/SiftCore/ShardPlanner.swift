//
// Copyright © Agulhas Labs
//

import Foundation

/// Decides which shard each test runs in, once, before anything is launched.
///
/// **Longest processing time first, ties broken by identifier.** The tests are ordered by what they are predicted to cost and each one goes to the shard carrying the least so far, which is the standard bound on how badly a static partition can end up skewed. Two tests predicted at the same cost are ordered by ``TestIdentifier/enumerated``, so the same set of tests plans the same way whatever order the enumeration happened to list them in — a plan that moved with its input would make two runs of one commit incomparable.
///
/// **Every shard is charged an overhead, and that is what lets the planner decline to split.** A shard is an `xcodebuild`, a simulator and a bundle load before it is any tests. The planner predicts every count from one up to the one asked for and keeps the highest count whose makespan is better by at least one shard's overhead — see ``paysForItself(_:against:overheadSeconds:)`` for why the bar is the overhead rather than any improvement at all.
public struct ShardPlanner: Sendable {
    /// What every shard is charged before its first test runs — process launch, test session start and bundle load.
    ///
    /// Measured on the demo project, 17 Sep 2026: 7 s for a unit bundle and around 39 s for a UI bundle, each over that bundle's own test time. This constant sits nearer the larger of the two deliberately. Underestimating it plans a shard that does not pay for itself — a whole extra simulator, boot and bundle load for tests that would have finished sooner beside the others — while overestimating it only declines a split that would barely have gained.
    public static let overheadSeconds: Double = 20

    /// What a test with no history is charged where no test in the plan has any: one second, which partitions by count.
    static let unknownTestSeconds: Double = 1

    /// The most shards this planner will ever plan onto, whatever `--shards` asks for.
    ///
    /// Each shard is a booted simulator: roughly 2–4 GB and a core or two. Packing is quadratic in the shard count considered — every count from one up to the one asked for is tried — so an unbounded `--shards` is not just more machine than the host has, it is unbounded planning work before anything launches.
    public static let maximumShards = 16

    /// The shards to run on this machine unless the caller says otherwise: `max(1, min(performance cores / 2, memory GB / 4, 3))`.
    ///
    /// Low on purpose, and capped at three. Three booted simulators beside three `xcodebuild`s is 6–12 GB, and host contention fails tight-timeout tests that pass alone — so the parallelism this command exists for is bounded by what the machine can run without changing what the tests measure.
    public static func defaultShardCount(performanceCores: Int, memoryGB: Int) -> Int {
        max(1, min(performanceCores / 2, memoryGB / 4, 3))
    }

    /// Partitions `tests` into at most `requested` shards, charging each test what `duration` says it costs.
    ///
    /// - Parameter duration: What a test has cost before, usually ``TestDurationStore/median(for:)``; `nil` for a test this repository has never timed.
    /// - Parameter overheadSeconds: What each shard pays before its first test; ``overheadSeconds`` unless a caller is measuring something else.
    /// - Parameter displayNames: The `@Test("…")` literals the index declares, which the plan carries untouched for the merge to attribute a quoted ending by; empty where there is no inventory to read.
    /// - Parameter conditional: The tests the index declares conditional, which the plan carries untouched for the merge to decide as the unsharded reconciliation does; empty where there is no inventory to read.
    public static func plan(
        tests: [TestIdentifier],
        shards requested: Int,
        overheadSeconds: Double = ShardPlanner.overheadSeconds,
        displayNames: [String: [TestIdentifier]] = [:],
        conditional: Set<TestIdentifier> = [],
        duration: (TestIdentifier) -> Double?
    ) -> ShardPlan {
        let known = tests.compactMap(duration)
        let estimate = median(of: known) ?? unknownTestSeconds
        // A target's tests resemble each other far more than they resemble another target's: measured on the
        // validation project, thirteen untimed UI tests of 4–27s each were charged the 0s median of the unit
        // tests beside them, and a three-shard run was planned as one.
        let knownByTarget = Dictionary(grouping: tests.filter { duration($0) != nil }, by: \.target)
            .compactMapValues { median(of: $0.compactMap(duration)) }
        let measured: [(test: TestIdentifier, seconds: Double)] = tests.map { test in
            (test: test, seconds: duration(test) ?? knownByTarget[test.target] ?? estimate)
        }
        // What each untimed test's target was actually charged, so the answer can say that instead of the
        // plan-wide median every one of them was charged before this — see ``ShardPlan/estimateNote``.
        var estimatedCharges: [String: EstimatedCharge] = [:]
        for test in tests where duration(test) == nil {
            if let targetMedian = knownByTarget[test.target] {
                estimatedCharges[test.target] = EstimatedCharge(seconds: targetMedian, source: .targetMedian)
            } else {
                estimatedCharges[test.target] = EstimatedCharge(seconds: estimate, source: .planMedian)
            }
        }
        let charged = measured.sorted { left, right in
            if left.seconds == right.seconds {
                return left.test.enumerated < right.test.enumerated
            }
            return left.seconds > right.seconds
        }
        let considered = max(1, min(requested, tests.count, maximumShards))

        var best = pack(charged, into: 1, overheadSeconds: overheadSeconds)
        var bestMakespan = makespan(of: best)
        var consideredMakespan = bestMakespan
        // A split is judged not to pay for itself only on measurements: where any test is an estimate the
        // count asked for is kept, since an estimate that is wrong low is exactly what would lower it.
        let measuredThroughout = known.count == tests.count
        for count in stride(from: 2, through: considered, by: 1) {
            let shards = pack(charged, into: count, overheadSeconds: overheadSeconds)
            let span = makespan(of: shards)
            if count == considered {
                consideredMakespan = span
            }
            // The extra shards have to save at least what they cost — see ``paysForItself(_:against:overheadSeconds:)``.
            if !measuredThroughout || paysForItself(span, against: bestMakespan, overheadSeconds: overheadSeconds) {
                best = shards
                bestMakespan = span
            }
        }

        let lowering = best.count < requested
            ? ShardPlan.Lowering(requested: requested, considered: considered, used: best.count, consideredMakespan: consideredMakespan)
            : nil
        return ShardPlan(
            shards: best,
            requestedShards: requested,
            overheadSeconds: overheadSeconds,
            estimatedTests: tests.count - known.count,
            estimatedSeconds: estimate,
            estimatedCharges: estimatedCharges,
            displayNames: displayNames,
            conditional: conditional,
            lowering: lowering
        )
    }
}

private extension ShardPlanner {
    /// How close two predicted makespans have to be to count as the same, so a sum that differs in its last bits does not buy a shard.
    static var tolerance: Double {
        1e-9
    }

    /// Whether a partition into more shards saves at least what the shards it adds cost — which is what "a shard that pays for itself" means.
    ///
    /// **A smaller makespan is not on its own a reason to split.** Every shard pays its own overhead, so under a plain minimum a higher count almost always wins by a hair — three tests worth a second between them would be planned onto three simulators to finish six tenths of a second sooner. The saving is measured against a shard's own overhead instead: an extra simulator, its boot and its bundle load are worth spending where they buy back at least as much wall clock as they cost, and nowhere else. That is the design's rule — *lowers N while another shard would not pay for itself* — and it is why the plan can answer with fewer shards than were asked for.
    static func paysForItself(_ span: Double, against best: Double, overheadSeconds: Double) -> Bool {
        span - (best - overheadSeconds) <= tolerance
    }

    /// The tests, already ordered longest first, dealt into `count` bins by always filling the one carrying the least.
    static func pack(_ charged: [(test: TestIdentifier, seconds: Double)], into count: Int, overheadSeconds: Double) -> [ShardPlan.Shard] {
        var tests = Array(repeating: [TestIdentifier](), count: count)
        var loads = Array(repeating: 0.0, count: count)
        for entry in charged {
            var target = 0
            // The lowest index wins a tie, which is what makes an even partition read the same way twice.
            for index in loads.indices where loads[index] < loads[target] - tolerance {
                target = index
            }
            tests[target].append(entry.test)
            loads[target] += entry.seconds
        }
        return (0 ..< count).map { index in
            ShardPlan.Shard(index: index + 1, tests: tests[index], predictedSeconds: overheadSeconds + loads[index])
        }
    }

    /// When the slowest of these shards is predicted to finish, which is when the run is.
    static func makespan(of shards: [ShardPlan.Shard]) -> Double {
        shards.map(\.predictedSeconds).max() ?? 0
    }

    /// The median of what the tests that have a history cost, or `nil` where none of them does.
    static func median(of seconds: [Double]) -> Double? {
        let sorted = seconds.sorted()
        guard !sorted.isEmpty else {
            return nil
        }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
