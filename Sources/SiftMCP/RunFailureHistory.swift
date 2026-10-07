//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// How often each test has been recorded failing, against how many runs recorded which tests failed at all.
///
/// **It counts and it never concludes**, on exactly the terms ``RunFailureShape`` sets out. *`theWellIsATarget()` was named in 3 of 12 runs that recorded their failures, most recently last Thursday* is a fact about a log. "That test is flaky" is a claim about cause, and the log cannot support it: three failures in twelve runs is what an intermittent test looks like, and it is equally what a real regression looks like when the change that caused it was present for exactly those three runs. The counts are the answer; what they mean is the reader's call, and a tool that guesses is eventually confidently wrong about a test somebody then stops trusting.
///
/// **The denominator is the population, stated, and it is not "runs of this test".** Nothing in `run.jsonl` says which tests a run executed — only which ones it reported failing — so what is counted is the runs that could have executed it: the runs filed under a key naming the same test-running command. That is wider than the truth in one direction only: a `swift test --filter` that ran a tenth of the suite sits in the denominator of a test it never selected, which makes a failure rate read lower than it is and never higher. The command is the one split the log supports, because a `swift build` cannot fail a test and putting nine of them behind a test's fraction would be an error of a different size entirely.
///
/// **A key that does not name one action is not a population, and is counted rather than listed.** A key naming the tool alone files `xcodebuild build`, `test`, `clean` and `archive` under the one word `xcodebuild`. That is not the over-count above wearing a bigger number — it breaks the membership test itself. A test named by *every* `xcodebuild test` run it was ever in is excluded by design, as a broken test rather than an inconsistent one; with 55 builds sharing its key it is named by 4 of 75 instead, listed as a test that "has both failed and passed", and printed with a fraction over a population that never existed. A regression served as a flake is read as "rerun it", which is the one reading this whole report is arranged to prevent. So those runs go to ``conflated`` and are reported as runs the report is *not* built on, on the same terms as ``unrecorded`` and ``incomplete``.
///
/// **The key carries the action, which is what gives the commonest command a population at all.** ``RunCommandKind/logKey(of:)`` writes `xcodebuild test` rather than the bare `xcodebuild`, and ``RunCommandKind/population(of:)`` groups the runs that share a denominator — `test` with `test-without-building`, and nothing else with either. Two things stay as they are. A line written by a version that recorded the bare word carries it permanently and stays ``conflated``, which on a machine with a long history of `xcodebuild` is most of its log for some time; and an invocation whose action argv leaves in doubt is written the same way and counted out the same way, deliberately, because the alternative is guessing a run into a population.
///
/// **The tree is a split, and it comes first.** A test that failed on one tree and passed on another is what a deliberate red looks like — a negative gate, a test written before its fix — and it is equally what a regression and its fix look like; a test that failed and passed on identical bytes is none of those. So each population is read over the runs that recorded their tree: ``sameTree`` holds the tests with both outcomes on one tree under one command line, and ``otherTrees`` the tests that failed only on trees, or under command lines, they never passed on. The command line is part of the key because the log keeps the tests that failed and not the tests that ran: a `--filter` run that never reached a test reads as a pass of it, and only runs given one command are known to have run one set of tests. A run that recorded no tree can be put in neither, and its tests are read on the single-tier terms that predate trees into ``unknownTree``.
///
/// **Root is deliberately not a split.** Every agent worktree is its own repository root, so grouping by root would cut one repository's history into a dozen populations of three, each too small to say anything. `--root` narrows the whole report when a reader wants one repository's own runs, which is the same vocabulary ``LogScope`` gives every other reader of these logs.
public struct RunFailureHistory: Sendable, Equatable {
    /// Per population, the tests that both failed and passed on one recorded tree under one command line, most runs first.
    public let sameTree: [PopulationHistory]

    /// Per population, the tests with both outcomes over the runs that recorded a tree, none of them on one tree.
    public let otherTrees: [PopulationHistory]

    /// Per population, the tests with both outcomes over the runs that recorded no tree, read as one pool because nothing says which of them shared one.
    public let unknownTree: [PopulationHistory]

    /// Runs in scope that recorded nothing about which tests failed.
    ///
    /// Counted and reported rather than dropped in silence, because it is the number that says how much of the log this report is *not* built on.
    public let unrecorded: Int

    /// Runs whose failures ran past ``RunUsageLog/failedTestCap``, so they cannot say a test did not fail.
    public let incomplete: Int

    /// Runs whose key does not say which action they ran, so they are no population to count a test against.
    ///
    /// The only such key is the bare word `xcodebuild` — see ``RunCommandKind/population(of:)``. These runs are the report's largest single omission on a machine that drives Xcode, which is why they are counted out loud rather than dropped: "counted in nothing above" is a different fact from "there were none".
    public let conflated: Int

    /// How many runs in scope recorded which tests failed *and* did so under a key that is a population — the denominator every fraction printed above is drawn from.
    ///
    /// Stored rather than summed over the tiers, which hold only the populations that turned up a test with both outcomes: a log of a hundred clean runs measured a hundred runs and has nothing to list, and a report that read its own coverage off the listing would say it had measured none of them.
    public let measured: Int

    /// How many of the ``measured`` runs recorded no tree, and so can be in neither of the two tiers.
    public let treeless: Int
}

public extension RunFailureHistory {
    /// One population, the runs in it a tier is over, and the tests inside it that the tier lists.
    struct PopulationHistory: Sendable, Equatable {
        /// The log keys whose runs make up this population, sorted — usually one, and two where `xcodebuild test` and `xcodebuild test-without-building` were both used.
        ///
        /// Kept as the keys rather than reduced to a name here, so the report can say which spellings a fraction is actually over. A fold printed under one member's name would stand 25 runs under a heading a third of them never matched — a smaller version of the defect that made this population necessary at all.
        public let keys: [String]

        /// The runs of this population the tier reads: those that recorded a tree in the two tiers, those that recorded none in the unknown one.
        public let runs: Int

        /// The tests the tier lists, most failures first, ties broken by name so the same log always renders the same way.
        public let tests: [TestHistory]
    }

    /// One test, how many runs named it out of how many it is counted over, and the last day one did.
    struct TestHistory: Sendable, Equatable {
        /// The test as the framework printed it — `theWellIsATarget()` from Swift Testing, `-[SuiteName testName]` from XCTest.
        ///
        /// Swift Testing prints no suite, so two functions of the same name in two suites are one row here. Nothing in the log distinguishes them, and inventing a distinction would be worse than the collision.
        public let name: String

        public let failed: Int

        /// The runs `failed` is out of: in the same-tree tier only the runs of the trees the test both failed and passed on, elsewhere every run the tier reads.
        public let runs: Int

        /// In the same-tree tier, how many trees the test both failed and passed on; `nil` in the other two, which are not counted per tree.
        public let trees: Int?

        /// The last day this test was named among the runs it is counted over, in the log's own UTC day.
        public let lastFailed: String
    }

    /// Tallies `scan` — the runs that can answer, the tests inside them by tree, and the runs that cannot.
    ///
    /// One pass over the entries and one over the names inside each. A test is listed only where it has both outcomes over the runs a tier reads: a test named by every run that could name it has failed and not passed, which is a broken test rather than an inconsistent one, and it is the run's own answer above rather than anything this has to say.
    ///
    /// The three disqualifications are asked in the order that keeps each count meaning one thing. ``conflated`` is asked last, so it is exactly the runs that would otherwise have been counted — a run that both overran the cap and carries an ambiguous key is filed under the cap, which is the fact that already disqualified it.
    static func of(_ scan: RunScan) -> RunFailureHistory {
        var known = Tally()
        var unknown = Tally()
        var unrecorded = 0
        var incomplete = 0
        var conflated = 0
        for entry in scan.entries {
            guard let failures = entry.failures else {
                unrecorded += 1
                continue
            }
            guard failures.namesThemAll else {
                incomplete += 1
                continue
            }
            guard let population = RunCommandKind.population(of: entry.kind) else {
                conflated += 1
                continue
            }
            // Every run without a tree is filed under one placeholder, because the unknown tier is read as one
            // pool per population; the two known tiers never see it.
            if let tree = entry.tree, let invocation = entry.invocation {
                known.add(entry, names: failures.named, population: population, on: Started(tree: tree, invocation: invocation))
            } else {
                unknown.add(entry, names: failures.named, population: population, on: Started(tree: "", invocation: ""))
            }
        }
        let tiers = known.tiers()
        let treeless = unknown.runs.values.reduce(0, +)
        return RunFailureHistory(
            sameTree: tiers.sameTree,
            otherTrees: tiers.otherTrees,
            unknownTree: unknown.pooled(),
            unrecorded: unrecorded,
            incomplete: incomplete,
            conflated: conflated,
            measured: known.runs.values.reduce(0, +) + treeless,
            treeless: treeless
        )
    }
}

private extension RunFailureHistory {
    /// A tree and the command line a run was given on it: the unit outcomes are compared within.
    struct Started: Hashable {
        let tree: String
        let invocation: String
    }

    /// One test's failures on one tree under one command line, and the last day it was named there.
    struct Named {
        var failed = 0
        var lastFailed = ""
    }

    /// The runs of each population, and each test's failures within them, split by tree.
    struct Tally {
        var runs: [String: Int] = [:]
        var keys: [String: Set<String>] = [:]
        var runsOnTree: [String: [Started: Int]] = [:]
        var named: [String: [String: [Started: Named]]] = [:]

        mutating func add(_ entry: RunScan.Entry, names: [String], population: String, on tree: Started) {
            runs[population, default: 0] += 1
            // The key as written, beside the population it was folded into: the fraction is over the fold
            // and the heading has to name what is in it.
            keys[population, default: []].insert(entry.kind)
            runsOnTree[population, default: [:]][tree, default: 0] += 1
            for name in names {
                var seen = named[population]?[name]?[tree] ?? Named()
                seen.failed += 1
                seen.lastFailed = max(seen.lastFailed, entry.day)
                named[population, default: [:]][name, default: [:]][tree] = seen
            }
        }

        /// The same-tree tier and the other-trees tier; a test lands in one of them or in neither, never both.
        func tiers() -> (sameTree: [PopulationHistory], otherTrees: [PopulationHistory]) {
            var sameTree: [PopulationHistory] = []
            var otherTrees: [PopulationHistory] = []
            for (population, count) in runs {
                let onTree = runsOnTree[population] ?? [:]
                var same: [TestHistory] = []
                var other: [TestHistory] = []
                for (name, byTree) in named[population] ?? [:] {
                    // A tree and command it both failed and passed under: named by some of those runs and not by all.
                    let both = byTree.filter { $0.value.failed < onTree[$0.key, default: 0] }
                    if !both.isEmpty {
                        same.append(TestHistory(
                            name: name,
                            failed: both.values.reduce(0) { $0 + $1.failed },
                            runs: both.keys.reduce(0) { $0 + onTree[$1, default: 0] },
                            trees: Set(both.keys.map(\.tree)).count,
                            lastFailed: both.values.map(\.lastFailed).max() ?? ""
                        ))
                    } else if let row = Self.pooledRow(name, byTree, over: count) {
                        other.append(row)
                    }
                }
                let spelled = (keys[population] ?? []).sorted()
                sameTree.append(PopulationHistory(keys: spelled, runs: count, tests: same))
                otherTrees.append(PopulationHistory(keys: spelled, runs: count, tests: other))
            }
            return (Self.ordered(sameTree), Self.ordered(otherTrees))
        }

        /// Every run read as one pool per population, which is the only reading runs with no tree allow.
        func pooled() -> [PopulationHistory] {
            Self.ordered(runs.map { population, count in
                PopulationHistory(
                    keys: (keys[population] ?? []).sorted(),
                    runs: count,
                    tests: (named[population] ?? [:]).compactMap { Self.pooledRow($0.key, $0.value, over: count) }
                )
            })
        }

        /// A test's row over `count` runs taken together, or `nil` when it failed in every one of them.
        static func pooledRow(_ name: String, _ byTree: [Started: Named], over count: Int) -> TestHistory? {
            let failed = byTree.values.reduce(0) { $0 + $1.failed }
            guard failed < count else { return nil }
            return TestHistory(name: name, failed: failed, runs: count, trees: nil, lastFailed: byTree.values.map(\.lastFailed).max() ?? "")
        }

        static func ordered(_ populations: [PopulationHistory]) -> [PopulationHistory] {
            populations
                .map { population in
                    PopulationHistory(
                        keys: population.keys,
                        runs: population.runs,
                        tests: population.tests.sorted { $0.failed == $1.failed ? $0.name < $1.name : $0.failed > $1.failed }
                    )
                }
                .filter { !$0.tests.isEmpty }
                .sorted { $0.runs == $1.runs ? $0.keys.lexicographicallyPrecedes($1.keys) : $0.runs > $1.runs }
        }
    }
}
