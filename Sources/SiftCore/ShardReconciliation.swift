//
// Copyright © Agulhas Labs
//

import Foundation

/// What a sharded run's shards add up to, taken against the tests the plan gave them rather than off any log's closing line.
///
/// **Every count here is this tool's own.** A sharded run has no tally worth believing — `xcodebuild` prints one per bundle per process, a crash restarts the runner and the relaunch's tally stands alone and reads green, and three shards print three of those. So the arithmetic starts from the expected set and asks each shard's log what became of the tests it was given.
///
/// **Not green is a state of the reconciliation, not of the logs.** A missing test, a duplicated one, a failure or a non-zero shard exit each make the run not green whatever any log declared, because each one means the answer cannot account for the set it was handed.
public struct ShardReconciliation: Sendable {
    /// The one line of arithmetic the answer is read on.
    public let counts: Counts

    /// One entry per shard that ran, in shard order.
    public let shards: [Shard]

    /// Every test a shard was given and reported no ending for, named with the shard that was given it.
    public let missing: [Missing]

    /// The tests a shard could only reconcile by count and came up short on, which are missing without being nameable.
    public let shortfalls: [Shortfall]

    /// Every test that ended more than once, once each.
    public let duplicated: [Duplication]

    /// The tests whose last attempt failed, in identifier order — the set the serial re-run line names.
    public let failed: [TestIdentifier]

    /// What each test cost, longest first, for the answer's slowest listing.
    public let timings: [Timing]

    /// The failures the shards' logs carried, and the failures their event streams recorded for tests that never started, in shard order, for the answer's classification block.
    public let failures: [RunTestFailure]

    /// The sentences this reconciliation owes about how it was arrived at — count-only groups, endings it could attribute to nothing, shards that were stopped rather than finished.
    public let notes: [String]

    /// How many shard results came back that the plan has no shard for, which are the ones nothing here read.
    ///
    /// A runner handing back more results than it was asked for has a defect, and the merge cannot say which of them is the stray — so the count stands on its own and the run is never green over it, because a result nobody read is a shard that could be hiding. `var` with a default, like ``ShardOutcome/timedOut``, because it is a fact about the merge's inputs rather than about any shard, and a reconciliation written by hand has none.
    public var resultsOutsideThePlan = 0

    /// Conditional tests a shard was given that reported nothing, in identifier order: switched off or lost, the log cannot say which, so they are counted in neither direction — as ``RunReconciliation/undecided`` counts them.
    public var undecided: [TestIdentifier] = []

    /// The members of ``undecided`` that share a name with other conditional tests whose endings did not reach them all, in identifier order: some of them reported and the count cannot say which, so the answer names them apart from a test that reported nothing — as ``RunReconciliation/undecidedInGroups`` names them.
    public var undecidedInGroups: [TestIdentifier] = []

    /// Every test a shard's event stream ended that `swift test list` never named, as `shard N: identifier`, which no shard expected and no count holds.
    ///
    /// The listing goes through the same relay that drops console lines under load, so a test can run with no shard owing it; the run is not green over one, since the expected set it was reconciled against was short.
    public var unlisted: [String] = []

    /// Every test the index declares that `swift test list` never named and no shard's stream ended, in identifier order: a suite the listing lost whole, which no shard ran and no count holds.
    public var neverListed: [TestIdentifier] = []

    /// The members of ``failed`` that no entry of ``failures`` names, in identifier order: a failed test whose console line was lost has no record to be listed under, so the answer names it on its own.
    ///
    /// Paired by ``ShardMerge``, which alone knows how a record's name names a test.
    public var unrecordedFailures: [TestIdentifier] = []
}

public extension ShardReconciliation {
    /// The reconciliation's arithmetic: `expected · ran · passed · failed · skipped · missing · duplicated`.
    ///
    /// Shared with the unsharded reconciliation under its own name, so the two paths cannot drift into two vocabularies for one answer.
    typealias Counts = ReconciliationCounts

    /// One shard's own numbers: what it was given, what it cost, and where to read the rest.
    struct Shard: Sendable {
        public let index: Int

        /// How many tests the plan gave this shard.
        public let testCount: Int

        /// How many times this shard ran its tests — more than one means the plan retried something.
        public let iterations: Int

        /// Launch to exit.
        public let wallSeconds: Double

        /// Every attempt's own seconds, summed — which cannot see launch, session start, bundle load or the gaps between tests.
        public let executionSeconds: Double

        /// What the plan predicted this shard would cost, kept beside what it did cost.
        public let predictedSeconds: Double

        public let exitCode: Int32
        public let logPath: String

        /// What this shard offers ``TestDurationStore``, eligible or not — the store itself decides whether to keep it.
        public let recording: TestDurationStore.Recording

        /// Whether this shard's log carries Swift Testing's closing `Test run with …` line — see ``ShardOutcome/closedWithRunSummary``.
        public var closedWithRunSummary = false

        /// Which of this shard's Swift Testing processes (1-based, in the order they started) printed no `Test run with …` line, and how many it ran, where exactly one of several did not, or `nil` where the log cannot name one.
        public var unclosedSwiftTestingRun: (position: Int, of: Int)?

        /// Whether this shard spent more than twice its tests' own time outside them, which is then the thing to fix rather than the tests.
        public var wallExceedsExecution: Bool {
            wallSeconds > 2 * executionSeconds
        }
    }

    /// A test a shard was given and never reported an ending for.
    struct Missing: Sendable, Equatable {
        public let shard: Int
        public let test: TestIdentifier
    }

    /// A count-only group that reported fewer endings than the shard expected tests in it, which is missing without a name to give.
    ///
    /// Swift Testing's log names a test by its function alone, so where one shard expects two tests declaring `formatsUppercase()` an ending cannot be matched to either. Reconciled by count instead: fewer endings than tests means one is missing, and saying *which* would be a guess — so the answer says how many of how many.
    struct Shortfall: Sendable, Equatable {
        public let shard: Int

        /// The function name every test in the group declares.
        public let function: String

        /// How many of the group never reported.
        public let missing: Int

        /// How many tests the group holds.
        public let expected: Int

        /// How many of the group are conditional in their declaration — see ``ReconciliationShortfall/conditional``.
        public var conditional = 0

        /// `1 of these 2 never reported` — what the answer can honestly say about a group it cannot name into.
        public var sentence: String {
            ReconciliationShortfall(function: function, missing: missing, expected: expected, conditional: conditional).sentence
        }
    }

    /// A test that ended more than once.
    struct Duplication: Sendable, Equatable {
        public let test: TestIdentifier

        /// The shards that reported an ending for it, in order.
        public let shards: [Int]

        /// Whether one shard ended it twice inside a single iteration — which is not a retry, and is the reading a retry is most easily mistaken for.
        public let withinIteration: Bool
    }

    /// One test's measured cost, for the slowest listing and for the duration store.
    struct Timing: Sendable, Equatable {
        public let shard: Int
        public let test: TestIdentifier

        /// The first attempt's seconds — the only attempt that is a timing of the test rather than of a retry.
        public let seconds: Double
    }
}

public extension ShardReconciliation {
    /// Whether this run may be reported as passing.
    ///
    /// Five ways to be not green and none of them is a log's opinion: a shard's process failed, a test failed, a test the plan named never reported, one reported twice, or a result came back that the plan has no shard for. The last three are the ones a tally cannot see, and they are why this type exists.
    ///
    /// A sixth is a run that expected nothing, because every planned test was conditional and reported nothing: it checked nothing either way, and the unsharded reconciliation is not green over it either.
    var isGreen: Bool {
        counts.expected > 0
            && shards.allSatisfy { $0.exitCode == 0 }
            && counts.failed == 0
            && counts.missing == 0
            && counts.duplicated == 0
            && resultsOutsideThePlan == 0
            && unlisted.isEmpty
            && neverListed.isEmpty
    }

    /// What `sift test` exits with: the first non-zero shard's code, else `1` where the reconciliation alone failed, else `0`.
    ///
    /// A shard's own code comes first because it is the more specific fact — 65 from `xcodebuild` says something a reader knows how to look up — and `1` stands for the case no shard reported: every process exited cleanly and the tests still do not add up.
    var exitCode: Int32 {
        if let failing = shards.first(where: { $0.exitCode != 0 }) {
            return failing.exitCode
        }
        return isGreen ? 0 : 1
    }

    /// The five slowest tests this run measured, longest first.
    var slowest: [Timing] {
        Array(timings.sorted { left, right in
            left.seconds == right.seconds
                ? left.test.enumerated < right.test.enumerated
                : left.seconds > right.seconds
        }.prefix(5))
    }

    /// What one shard offers the duration store, or `nil` where no shard has that index.
    func recording(forShard index: Int) -> TestDurationStore.Recording? {
        shards.first { $0.index == index }?.recording
    }
}
