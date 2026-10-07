//
// Copyright © Agulhas Labs
//

import Foundation

/// What a wrapped run produced: the exit code it must be reported with, and the filtered answer if there is a usable one.
public struct RunOutcome {
    public let kind: RunCommandKind

    /// How this run files itself in `~/.sift/run.jsonl` — the tool, and the action where argv named one.
    ///
    /// A second, finer answer to the question ``kind`` answers, and both are needed: the kind decides which filter runs, which is settled by the executable alone, while the key decides which runs a later report may count this one among, which needs the action too. Forcing one value to carry both would make `xcodebuild build` and `xcodebuild test` unequal kinds, and every `== .xcodebuild` in the tree would quietly start meaning something narrower.
    ///
    /// Carried on the outcome rather than worked out again by the caller that files it, for the reason ``repositoryRoot`` is carried: the launcher is the one place holding argv, and a key derived a second time somewhere else is a second place for the rule to drift.
    public let logKey: String

    /// The wrapped command's exit code, passed through untouched — this is the one part of `run` nothing is allowed to reinterpret.
    public let exitCode: Int32
    /// `nil` when no filter applied to this command.
    public let report: RunReport?
    public let log: RunLog?

    /// The repository the command ran in, or `nil` outside one.
    ///
    /// Carried on the outcome rather than rediscovered by the caller because discovering it costs a `git` process, and the launcher has already paid for one on its way to excluding the cache directory.
    public let repositoryRoot: URL?

    public init(kind: RunCommandKind, logKey: String, exitCode: Int32, report: RunReport?, log: RunLog?, repositoryRoot: URL?) {
        self.kind = kind
        self.logKey = logKey
        self.exitCode = exitCode
        self.report = report
        self.log = log
        self.repositoryRoot = repositoryRoot
    }
}

public extension RunOutcome {
    /// A filtered answer and what it cost, so its receipt and the run log state one number rather than two.
    struct Answer: Sendable {
        /// The text served to the caller.
        public let text: String
        /// How many lines that text carries — the number its own receipt states, and the number the run log records as this run's cost.
        public let lines: Int
    }

    /// The filtered answer, or `nil` when the raw output has to go out instead.
    ///
    /// - Parameter accessibility: What re-arming the accessibility preference did on each simulator this run named, in argv order — one line per device that owes one, and one qualification on its headline. Empty prints nothing about a device.
    /// - Parameter testBundles: How many test bundles this run was owed a count from, which its own log cannot say — taken as a value, since it is read from the package rather than from the run and the caller holds the argv that decides whether it can be read at all. The default is that nobody asked, and the answer then says nothing about a bundle that never reported.
    /// - Parameter inventory: What ``RunInventoryCheck`` said about the run, placed under its totals line; empty says nothing.
    func filteredAnswer(workingDirectory: URL, accessibility: [SimulatorAccessibility.Restoration] = [], testBundles: RunTestBundles = .undetermined, selector: RunTestSelector? = nil, inventory: [String] = []) -> Answer? {
        guard let report, report.isUsable(exitCode: exitCode) else {
            return nil
        }
        let text = RunReportRenderer(
            kind: kind,
            workingDirectory: workingDirectory,
            changedFiles: changedFiles(of: report),
            sites: sites(of: report),
            accessibility: accessibility,
            testBundles: testBundles,
            selector: selector,
            inventory: inventory
        )
        .render(report, exitCode: exitCode, logURL: log?.url)
        // An identity rather than a measurement: the renderer joined its lines with newlines, so splitting
        // them back apart returns the count its receipt has already stated. Taken here so the caller that
        // files this run has the answer's own size to record and never a number worked out beside it.
        return Answer(text: text, lines: text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    /// The did-not-build headline the raw-output fallback owes, when ``filteredAnswer`` has refused to answer and this selected run's own exit code is nonetheless the one ``RunTestSelector/didNotBuild(_:exitCode:)`` names.
    ///
    /// A build that failed with nothing at a `file:line` and no test process ever opened leaves `report.isUsable(exitCode:)` false — `errors` and `testFailures` are both empty — so `filteredAnswer` serves nothing and the whole transcript goes out instead. That transcript is not unexplained: `RunTestSelector.didNotBuild` already reads `Testing cancelled because the build failed.` as positive evidence with no error line to point at, and `sift run` exits accordingly. The raw log still has to go out — nothing else says *what* failed to build — but the line introducing it must say the one thing the filter does know, not that it knows nothing.
    func didNotBuildFallbackHeadline(selector: RunTestSelector?) -> String? {
        guard let report, let selector, selector.didNotBuild(report, exitCode: exitCode) else {
            return nil
        }
        return RunTestSelector.didNotBuildHeadline(label: kind.label, exitCode: exitCode)
    }

    /// The names of the tests this run reported failing, or `nil` when the run is in no position to say.
    ///
    /// **`nil` and `[]` are different answers and the difference is the whole contract.** `[]` is a run that read its own output and found no test failing in it; `nil` is a run that cannot speak to the question at all, and the history built on this must count it as unknown rather than as a run everything passed in — a wrong "it has never failed before" is exactly the answer that gets believed.
    ///
    /// Four runs answer `nil`, each for a reason of its own. A passthrough has no report, because no filter ran. A run whose failure the filter could not explain fails ``RunReport/isUsable(exitCode:)`` — the fail-open branch served its raw log precisely because nobody knows what went wrong in it, and a test runner that crashed before reporting takes its whole suite down silently. A run that printed diagnostics and named no failing test never reached its tests at all: a suite that did not compile did not pass, and counting it as a run everything survived is how a real failure rate gets quietly divided by the builds that never ran.
    ///
    /// **And a run with no verdict.** A log that stops mid-suite, or one whose action this tool would not read, arrives here with empty failures and empty errors, and answering `[]` for it would file a run that *named* its failures, as `"failed": [], "failed_total": 0`, counted into every denominator `flakes` divides by. The same report's own headline reads `⚠ … no verdict in the log`, so the two consumers of one answer would contradict each other outright. A run that cannot say how it ended cannot say what failed in it, and the same goes for one that was ``RunVerdict/State/interrupted``: it was killed before it could judge itself, so the failures it had named by then are a fragment of a suite that never finished rather than a statement about it.
    ///
    /// **One exception is admitted rather than hidden.** An `xcodebuild -quiet` run prints no closing line on a pass, so its silence over exit 0 is read as one (``RunVerdict/inferredFromExitCode``) and answers `[]` — and a `-quiet` run cut short that still exited 0 is the same silence, so it answers `[]` too. Nothing in its log tells the two apart; the answer's own note says the pass rests on the exit code for that reason. Without `-quiet` a silent log is never read as a pass, and still answers `nil` here.
    var reportedTestFailures: [String]? {
        guard let report, report.isUsable(exitCode: exitCode) else {
            return nil
        }
        guard let verdict = report.verdict, verdict.state != .interrupted, report.testCrash == nil else {
            return nil
        }
        guard !report.testFailures.isEmpty || report.errors.isEmpty else {
            return nil
        }
        return report.testFailures.map(\.name)
    }

    /// Whether this run may stand for the tree it ran on — the one judgement the proved-run ledger records against a ``TreeKey``.
    ///
    /// **It is the `✔ passed` of the answer and nothing weaker.** Every clause the answer would print as an anomaly is a clause that stops a record being written, because a record exists to let a later gate skip the suite entirely: a run whose bundle never launched, whose process died silently, or whose pass is read from an exit code rather than from a line the tool printed is a run nobody may stand on.
    ///
    /// **A failing run can never reach this.** A nonzero exit, a named test failure, an error, or a verdict that is not ``RunVerdict/State/succeeded`` each answer `false`, and nothing here records anything for a `false` — an absent record is a suite that runs, which is the direction every doubt resolves in.
    ///
    /// `--parallel` refuses for a reason of its own: under it neither framework's counters are complete, so the pass is real but nothing in the log says what it was a pass *of*, and the answer already marks it with a warning glyph rather than a tick.
    ///
    /// **A run that named its tests must show one ran**, and every `--filter` it named must have matched one (``RunTestSelector/unmatchedFilters(_:exitCode:)``). With a `selector`, a log that carries no test outcome and no closing count above 0 proves nothing, whatever its verdict: `xcodebuild`'s parallel testing prints only a suite's start and `** TEST EXECUTE SUCCEEDED **` for an `-only-testing:` identifier that matched nothing, and a `-quiet` pass is as silent — the one cannot be told from the other, so neither is recorded.
    ///
    /// - Parameter testBundles: What the package's own manifest says the run was owed, read by the caller that holds argv — ``RunTestBundles/undetermined`` makes no claim and blocks nothing, exactly as it prints nothing.
    /// - Parameter selector: The tests the command named (``RunTestSelector/named(in:)``), or `nil` for a run that named none.
    func provedGreen(testBundles: RunTestBundles, selector: RunTestSelector? = nil) -> Bool {
        guard exitCode == 0, let report, let verdict = report.verdict else {
            return false
        }
        guard verdict.state == .succeeded, !verdict.inferredFromExitCode, verdict.answersTheInvokedCommand else {
            return false
        }
        guard report.testFailures.isEmpty, report.errors.isEmpty, !report.parallelSwiftTest else {
            return false
        }
        guard report.testProcessOpenings == report.testProcessClosings else {
            return false
        }
        guard selector == nil || RunTestSelector.showsATestRan(report) else {
            return false
        }
        guard selector?.unmatchedFilters(report, exitCode: exitCode).isEmpty ?? true else {
            return false
        }
        guard !RunTestSelector.executedNothing(report, exitCode: exitCode, testBundles: testBundles) else {
            return false
        }
        let reported = report.reportedBundleCount
        return (testBundles.count ?? reported) <= reported
    }

    /// What the working tree has changed, asked for exactly when this answer is going to print the number.
    ///
    /// Two guards, each saving a process on the path a caller is waiting on: a run with nothing to classify never asks, and a run outside a repository answers from `repositoryRoot` — already discovered by the launcher — rather than paying `git` to rediscover that there is nothing to discover.
    ///
    /// **Both sections count, and the test is simply whether either has anything in it.** The measurement line stands over a listing as well as over a sample, so a run with one error prints the field and has to have asked for it. What that costs is a `git diff` on every run with something to report — a working-tree query already measured at 20ms, on a path the caller is waiting on only because something has already gone wrong.
    ///
    /// A run with nothing to report still never asks, and the answer there is *not consulted* rather than an empty set of names. That is the whole reason to spell it out: `.of([])` renders as **0 in changed files** — git was asked and reported nothing — which is the one thing ``RunChangedFiles`` says must never happen. A signal nobody asked for is absent, never zero.
    private func changedFiles(of report: RunReport) -> RunChangedFiles {
        guard !report.testFailures.isEmpty || !report.errors.isEmpty else {
            return .unavailable("the working tree was not consulted")
        }
        guard let repositoryRoot else {
            return .unavailable("not a git repository")
        }
        return .inWorkingTree(at: repositoryRoot)
    }

    /// Whether this run's failures have the shape of an empty in-process accessibility tree — the same detector a filtered answer's device notes consult, asked directly so the raw-log fallback can still say what an unreachable answer would have.
    ///
    /// A fail-open run has no filtered answer to read this from, but the report it fell open from is still sitting on ``report`` with its failures already parsed — `nil` only where there is no report at all, never merely because the answer above this one refused.
    func failuresReadEmptyTrees(workingDirectory: URL, accessibility: [SimulatorAccessibility.Restoration]) -> Bool {
        guard let report else {
            return false
        }
        return RunReportRenderer(
            kind: kind,
            workingDirectory: workingDirectory,
            changedFiles: changedFiles(of: report),
            sites: sites(of: report),
            accessibility: accessibility
        ).deviceNotes(of: report).leadFailures
    }

    /// The declarations this run's failures happened inside, asked for exactly when this answer is going to print them.
    ///
    /// The same two guards the changed-files signal answers to, for the same reason: a run with nothing to say about test failures never pays for this, and a run outside a repository has nowhere to ask. Errors are deliberately not resolved — the compiler already prints `File.swift:2:15: error: …`, which points at the exact token and is a `Read` target as it stands, so a second line naming the enclosing declaration would restate what the reader is one keystroke from seeing. A test failure is the asymmetric case, and the whole reason for this: the framework prints the *test's* name beside a line that may belong to a helper, and only the code can settle which.
    ///
    /// **Every failure's location is offered, not only the ones the block will illustrate.** Which five signatures a shape shows is decided downstream of here, and reconstructing that decision to narrow the request would mean running the census twice and keeping the two copies agreeing forever. ``RunFailureSites`` bounds its own work instead — a file cap taken in order of how many failures name each file, under a wall-clock budget — which is a bound this type does not have to know the shape of.
    private func sites(of report: RunReport) -> RunFailureSites {
        guard !report.testFailures.isEmpty, let repositoryRoot else {
            return .none
        }
        return .resolving(report.testFailures.compactMap(\.location), inRepositoryAt: repositoryRoot)
    }
}
