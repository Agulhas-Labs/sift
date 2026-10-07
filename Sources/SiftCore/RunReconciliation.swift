//
// Copyright © Agulhas Labs
//

import Foundation

/// What an ordinary, unsharded test run did, set against what the index says was supposed to run.
///
/// A runner's own tally counts whatever reported: a process that dies part-way takes the tests that never started out of the arithmetic entirely, and the summary can read green over a suite half of which never executed. The static inventory is the only thing that holds the other number, so the join between them is the only place that gap is visible.
public struct RunReconciliation: Sendable {
    /// The one line of arithmetic the answer is read on, in the same words the sharded reconciliation uses.
    public let counts: ReconciliationCounts

    /// What bounded the expected set, so a reader can see which tests this answer was never about.
    public let scope: Scope

    /// How many times the command ran its tests — more than one means something was retried.
    public let iterations: Int

    /// Every test expected to report an ending that reported none, in identifier order.
    public let missing: [TestIdentifier]

    /// The groups one reported name could not be told apart by, that came up short on endings.
    public let shortfalls: [ReconciliationShortfall]

    /// Every expected test that printed a Swift Testing start line and no ending inside a run whose summary passed and that printed its suite passing, in identifier order.
    ///
    /// Its own result line was lost on the way to the log, and the suite's pass line and the run summaries account for it, so it is neither missing nor reported.
    public var lost: [TestIdentifier] = []

    /// The groups one reported name could not be told apart by whose shortfall lost result lines account for, on the same terms as ``lost``.
    public var lostByCount: [ReconciliationShortfall] = []

    /// Every test that ended more than once inside a single iteration, once each.
    public let duplicated: [Duplication]

    /// The tests whose last attempt failed, in identifier order.
    public let failed: [TestIdentifier]

    /// Tests whose body opens `XCTFail(…)`, with whatever the run reported for them, counted in nothing.
    public let excluded: [Excluded]

    /// Conditional tests the run reported nothing for, which are counted in neither direction rather than guessed at.
    public let undecided: [TestIdentifier]

    /// The members of ``undecided`` that share a name with other conditional tests whose endings did not reach them all, in identifier order: some of them reported and the count cannot say which, so the answer names them apart from a test that reported nothing.
    public var undecidedInGroups: [TestIdentifier] = []

    /// Reported names that claimed no test in scope and no test's display name joined to one either, in the order `TestNameMatch.unclaimed` describes.
    public let unclaimed: [String]

    /// Test targets the index declares tests in that this run's container does not hold, so nothing here judges them.
    public let outsideScope: [OutsideScope]

    /// The sentences this reconciliation owes about how it was arrived at.
    public let notes: [String]

    /// Tests declared inside an `#if` clause this platform provably does not compile, such as `#if os(Linux)` on macOS, in identifier order: never run here, so counted in neither direction and named apart.
    public var compiledOut: [TestIdentifier] = []

    /// The tests whose last attempt the runner itself reported skipped, which ran no body: a `.disabled` Swift Testing test or an `XCTSkip`.
    ///
    /// A group reconciled by count alone carries no names, so ``ReconciliationCounts/skipped`` can exceed this list's size.
    public var skipped: [TestIdentifier] = []
}

public extension RunReconciliation {
    /// The container that bounded the expected set.
    ///
    /// A plan's `containerPath` bounds a sharded run; a package manifest bounds `swift test` the same way, and for the same reason — reconciling a package's run against every test the index holds would report every test of a sibling Xcode project missing over a run that was never about them.
    struct Scope: Sendable, Equatable {
        /// The manifest read, repository-relative.
        public let manifest: String

        /// The test targets it declares, sorted, which are the only targets this answer judges.
        public let targets: [String]

        /// Whether any `.testTarget` sits inside an `#if`, so the list above is one configuration's rather than the package's.
        public let conditionalTargets: Bool

        /// Where the run's output was read from, repository-relative where it sits under the repository.
        public let logPath: String

        public init(manifest: String, targets: [String], conditionalTargets: Bool, logPath: String) {
            self.manifest = manifest
            self.targets = targets
            self.conditionalTargets = conditionalTargets
            self.logPath = logPath
        }
    }

    /// A test that ended more than once within one iteration, which no retry does and no framework prints by accident.
    struct Duplication: Sendable, Equatable {
        public let test: TestIdentifier

        /// The iteration that ended it more than once.
        public let iteration: Int

        /// How many endings that iteration printed for it.
        public let endings: Int
    }

    /// A test switched off in source by an `XCTFail(…)` opening its body, and what the run made of it.
    ///
    /// It reports as an ordinary failure on every surface, so nothing but a static read tells it from a real one — which is the whole reason it is lifted out here instead of being counted.
    struct Excluded: Sendable, Equatable {
        public let test: TestIdentifier

        /// How the run ended it, or `nil` where the run reported nothing for it at all.
        public let ending: RunTestOutcomes.Ending?
    }

    /// A test target outside the run's container, named with how many tests the index declares in it.
    struct OutsideScope: Sendable, Equatable {
        public let target: String
        public let declared: Int
    }

    /// Whether this run may be reported as passing.
    ///
    /// A missing or duplicated test makes it not green whatever the runner's own summary said: that is the whole point of reconciling. An ending that claimed no test is stated rather than fatal — an extra test running is not a reason to fail a run that otherwise adds up.
    ///
    /// **A reconciliation that expected nothing is not green either.** Nothing expected means nothing was checked — a log from another repository, or a container whose targets hold none of the tests the index declares — and a run this answer checked nothing of is otherwise indistinguishable from one it checked entirely. The one verdict a reconciliation may never give is a pass it did not earn.
    var isGreen: Bool {
        counts.expected > 0 && counts.failed == 0 && counts.missing == 0 && counts.duplicated == 0
    }
}
