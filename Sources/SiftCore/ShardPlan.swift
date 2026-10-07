//
// Copyright © Agulhas Labs
//

import Foundation

/// The static partition of one run's tests across the shards that will run them, with what each shard is predicted to cost.
///
/// **Everything here is a prediction and none of it is a measurement.** What the shards actually cost comes back in ``ShardReconciliation``, and the answer stands the two beside each other — a partition that predicted badly is a fact about the durations on disk, and it is only visible where the predicted number is still there to compare against.
///
/// **A shard's predicted seconds include the overhead it pays before its first test runs**, because that is what makes the arithmetic of lowering the shard count readable: two shards each carrying a second of tests are predicted at ``ShardPlanner/overheadSeconds`` and a bit, and one shard carrying both is predicted at the same overhead paid once.
public struct ShardPlan: Sendable, Equatable {
    /// The shards, numbered from 1, in the order the planner filled them.
    public let shards: [Shard]

    /// The shard count the caller asked for, before the planner clamped it to the test count or lowered it.
    public let requestedShards: Int

    /// What every shard in this plan was charged before its first test — see ``ShardPlanner/overheadSeconds``.
    public let overheadSeconds: Double

    /// How many of the planned tests had no recorded duration and were charged ``estimatedSeconds`` instead.
    public let estimatedTests: Int

    /// What a test with no recorded duration was charged in this plan.
    public let estimatedSeconds: Double

    /// Every target with an untimed test, mapped to what its untimed tests were actually charged and where that charge came from — its own median where it had one, ``estimatedSeconds`` otherwise.
    public let estimatedCharges: [String: EstimatedCharge]

    /// Why this plan has fewer shards than were asked for, or `nil` where it has as many as were asked for.
    public let lowering: Lowering?

    /// The tests the index says declare their own `@Test("…")` literal, grouped under the name a log prints them by.
    ///
    /// **A shard's tests are identifiers, and a display name is the one thing an identifier cannot carry**, so an ending printed under a literal names nothing in the shard it ran in. This is how the literal reaches the merge: the plan is the only thing a shard's reconciliation is read against, and without it the merge has no second reading of that ending at all — see ``ShardMerge``.
    ///
    /// Empty where the run had no inventory to read — a repository with no index, or an index that could not be read — and a plan carrying an empty map reconciles exactly as every plan did before one carried any: the ending is stated and the test it belongs to is reported missing.
    public let displayNames: [String: [TestIdentifier]]

    /// The tests the index says are conditional in their declaration, which the merge decides as the unsharded reconciliation does: one that reported nothing is undecided rather than missing.
    ///
    /// Empty where the run had no inventory to read, and every planned test is then owed an ending.
    public let conditional: Set<TestIdentifier>

    /// The tests the index declares that the listing never named, which no shard was given and the run is not green over — see ``PackageShardPlanner/neverListed(declaredIn:listed:repositoryRoot:)``, less those a complete later listing also lacked — see ``PackageShardPlanner/confirmed(neverListed:listed:relisting:)``.
    ///
    /// Empty where the run had no inventory to read, and for a simulator run, whose expected set is not a listing.
    public var neverListed: [TestIdentifier] = []

    /// Why ``neverListed`` stands unconfirmed — the listing run to confirm it failed, or none named every test the first did — or `nil` where a listing confirmed it, or it is empty.
    public var neverListedNote: String?

    /// Memberwise, with `estimatedCharges`, `displayNames` and `conditional` defaulted to empty for a caller that has no per-target charge and no inventory to report.
    init(
        shards: [Shard],
        requestedShards: Int,
        overheadSeconds: Double,
        estimatedTests: Int,
        estimatedSeconds: Double,
        estimatedCharges: [String: EstimatedCharge] = [:],
        displayNames: [String: [TestIdentifier]] = [:],
        conditional: Set<TestIdentifier> = [],
        lowering: Lowering?
    ) {
        self.shards = shards
        self.requestedShards = requestedShards
        self.overheadSeconds = overheadSeconds
        self.estimatedTests = estimatedTests
        self.estimatedSeconds = estimatedSeconds
        self.estimatedCharges = estimatedCharges
        self.displayNames = displayNames
        self.conditional = conditional
        self.lowering = lowering
    }
}

public extension ShardPlan {
    /// One shard: the tests it will run, and what running them there is predicted to cost.
    struct Shard: Sendable, Equatable {
        /// Which shard this is, counting from 1 — the number the answer, the device name and the log path all carry.
        public let index: Int

        /// The tests this shard will be given, longest predicted first.
        public let tests: [TestIdentifier]

        /// The shard's overhead plus the predicted seconds of every test in it.
        public let predictedSeconds: Double
    }

    /// The planner settling on fewer shards than were asked for, and what the higher count was predicted to cost.
    struct Lowering: Sendable, Equatable {
        /// The count the caller asked for.
        public let requested: Int

        /// The highest count the planner considered — ``requested`` clamped to the number of tests there are to split.
        public let considered: Int

        /// The count it settled on.
        public let used: Int

        /// What the slowest shard was predicted to cost at ``considered``, which is what the extra shards would have bought.
        public let consideredMakespan: Double
    }
}

public extension ShardPlan {
    /// How many tests this plan partitions.
    var testCount: Int {
        shards.reduce(0) { $0 + $1.tests.count }
    }

    /// The longest any one shard is predicted to take, which is what the run as a whole is predicted to take.
    var predictedMakespan: Double {
        shards.map(\.predictedSeconds).max() ?? 0
    }

    /// The sentence the answer owes when this plan has fewer shards than were asked for, or `nil` when it has as many.
    ///
    /// Two causes, and they are worded separately because they are different facts: there were fewer tests than shards asked for, and an extra shard would not have paid for its own overhead. A plan can owe both sentences at once.
    var loweringNote: String? {
        guard let lowering else {
            return nil
        }
        var sentences: [String] = []
        if lowering.considered < lowering.requested {
            if lowering.considered == ShardPlanner.maximumShards, ShardPlanner.maximumShards < testCount {
                sentences.append("\(Self.shardCount(lowering.requested)) asked for; \(ShardPlanner.maximumShards) is the most sift will ever plan onto, since every shard is a booted simulator.")
            } else {
                sentences.append("\(Self.shardCount(lowering.requested)) asked for over \(testCount) test\(testCount == 1 ? "" : "s"), so \(lowering.considered) is the most there was work for.")
            }
        }
        if lowering.used < lowering.considered {
            sentences.append("Planned \(Self.shardCount(lowering.used)) rather than \(lowering.considered): at \(lowering.considered) the slowest shard is predicted at \(ShardSeconds.text(lowering.consideredMakespan)) against \(ShardSeconds.text(predictedMakespan)) here, because every shard pays \(ShardSeconds.text(overheadSeconds)) of launch, session start and bundle load before its first test runs.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The sentence the answer owes when some of the plan's tests were charged a duration nobody measured for them, or `nil` when every test had one.
    var estimateNote: String? {
        guard estimatedTests > 0 else {
            return nil
        }
        guard estimatedTests < testCount else {
            return "No test in this plan has a recorded duration, so all \(testCount) were charged \(ShardSeconds.text(estimatedSeconds)) and the partition is even by count alone."
        }
        var note = estimatedChargeSentence
        if requestedShards > 1 {
            note += " The shard count asked for was kept: a split is only judged not to pay for itself on measurements."
        }
        return note
    }
}

private extension ShardPlan {
    /// `1 shard` or `3 shards`, so a sentence about a count reads as one.
    static func shardCount(_ count: Int) -> String {
        "\(count) shard\(count == 1 ? "" : "s")"
    }

    /// What was actually charged to the plan's untimed tests, worded truthfully whether one value covered all of them or their targets differed.
    var estimatedChargeSentence: String {
        let distinctSeconds = Set(estimatedCharges.values.map(\.seconds))
        guard distinctSeconds.count > 1 else {
            // Sorted by target name rather than read off the dictionary's own order, which is not fixed: two
            // targets charged the same seconds from different sources would otherwise word the sentence
            // differently from one run to the next for the identical plan.
            let charge = estimatedCharges.sorted { $0.key < $1.key }.first?.value
            let seconds = charge?.seconds ?? estimatedSeconds
            let source = charge?.source == .targetMedian ? "their target's" : "the plan's"
            return "\(estimatedTests) of \(testCount) tests have no recorded duration and were charged \(ShardSeconds.text(seconds)), the median of \(source) timed tests."
        }
        let byTarget = estimatedCharges.sorted { $0.key < $1.key }
            .map { "\($0.key) \(ShardSeconds.text($0.value.seconds))" }
            .joined(separator: ", ")
        return "\(estimatedTests) of \(testCount) tests have no recorded duration and were charged their own target's median where it has one (\(byTarget)), else the plan's."
    }
}
