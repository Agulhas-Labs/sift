//
// Copyright © Agulhas Labs
//

import Foundation

/// What `sift run` adds under a `swift test` answer: the run's own outcomes set against the inventory the index declares, or why that was not done.
///
/// A runner's tally counts whatever reported, so a test process that died takes the tests it never reached out of the arithmetic and the summary can read green over them. The join is `sift test --analyse --against`'s, made on the outcomes the run already parsed; it is a note and never a verdict, so the exit code stays the wrapped command's.
public enum RunInventoryCheck: Sendable {
    /// The run was reconciled against the declared inventory.
    case reconciled(RunReconciliation)
    /// The run was in scope and could not be reconciled, for the reason given.
    case skipped(String)

    /// How long bringing the index up to date and reconciling may take before the check is skipped rather than waited on.
    public static let freshenBudget: TimeInterval = 20

    /// How many names a line lists before it counts the rest.
    static let listedNames = 5

    /// The lines the answer carries: one when the run adds up or could not be checked, and the names and qualifications when it does not.
    public var lines: [String] {
        switch self {
        case let .skipped(reason):
            ["inventory: not checked — \(reason)"]
        case let .reconciled(reconciliation):
            Self.lines(for: reconciliation)
        }
    }

    /// The lines the answer carries beside `crash`, never the clean form where a test process died: a test that never ran reports nothing, so the declared and reported counts can agree over it.
    public func lines(after crash: RunTestCrash?) -> [String] {
        guard let crash, case let .reconciled(reconciliation) = self else {
            return lines
        }
        return Self.lines(for: reconciliation, crash: crash)
    }
}

public extension RunInventoryCheck {
    /// Whether a run of `arguments` is one the inventory bounds: an unnarrowed, serial `swift test` of the package at the repository's root that reported at least one test.
    ///
    /// The bound is `--against`'s own — the root manifest's test targets — so anything that runs another set is out of it and says nothing: a filtered or skipped run, another package, a `--parallel` run whose log names only some of its tests, and an `xcodebuild` run, whose set is its scheme's.
    ///
    /// - Parameter executedNothing: Whether the run exited 0 having executed no test in a package that declares test targets (``RunTestSelector/executedNothing(_:exitCode:testBundles:)``): it reported none, and is bounded all the same, since the declared count is what says how much it missed.
    static func applies(to arguments: [String], report: RunReport, workingDirectory: URL, repositoryRoot: URL, executedNothing: Bool = false) -> Bool {
        let narrowing = RunTestBundles.narrowingOptions + ["--parallel"]
        guard RunCommandKind.recognize(arguments) == .swiftTest,
              !report.testOutcomes.isEmpty || executedNothing,
              !report.parallelSwiftTest,
              !arguments.contains(where: { argument in narrowing.contains { argument == $0 || argument.hasPrefix($0 + "=") } })
        else {
            return false
        }
        return packageRoot(above: workingDirectory).map(CanonicalPath.of) == CanonicalPath.of(repositoryRoot.path)
    }

    /// Reconciles `outcomes` against the index at `repositoryRoot`, brought up to date first as `--against` does, and never builds an index that is not there.
    ///
    /// - Parameter executedNothing: Whether the run executed no test, as ``applies(to:report:workingDirectory:repositoryRoot:executedNothing:)`` takes it: its empty outcomes reconcile as zero reported, so the line names every declared test that never reported.
    static func check(_ outcomes: RunTestOutcomes, loggedAt logURL: URL?, repositoryRoot: URL, budget: TimeInterval = freshenBudget, executedNothing: Bool = false) -> RunInventoryCheck {
        let database = SiftPaths.cache(in: repositoryRoot).appendingPathComponent(SiftPaths.indexFileName)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return .skipped("this checkout has no sift index yet, and building one is not this run's to pay for (`sift index` builds it)")
        }
        let box = CheckBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let check: RunInventoryCheck
            do {
                let engine = try SiftEngine(directory: repositoryRoot)
                try await engine.ensureFresh()
                check = try .reconciled(engine.reconcileRun(outcomes, loggedAt: logURL, executedNothing: executedNothing))
            } catch {
                check = .skipped("the inventory could not be read: \(error)")
            }
            box.store(check)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + budget) == .success, let check = box.value else {
            return .skipped("bringing the index up to date and reconciling took longer than \(Int(budget)) s")
        }
        return check
    }
}

private extension RunInventoryCheck {
    /// The nearest directory at or above `directory` holding a `Package.swift`, which is the package `swift test` runs there.
    static func packageRoot(above directory: URL) -> String? {
        var current = directory.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            // `/`'s parent is spelled `/..`, never `/`, so the root itself is the end of the walk.
            guard parent.path != current.path, current.path != "/" else {
                return nil
            }
            current = parent
        }
    }

    static func lines(for reconciliation: RunReconciliation, crash: RunTestCrash? = nil) -> [String] {
        let counts = reconciliation.counts
        guard counts.expected > 0 else {
            let lifted = RunReconciliationRenderer.liftedClauses(reconciliation)
            guard lifted.isEmpty else {
                return ["inventory: not checked — every test the index declares in the targets \(reconciliation.scope.manifest) bounds was lifted out of the counts (\(lifted.joined(separator: " · "))), so there was nothing to reconcile against"]
            }
            return ["inventory: not checked — the index declares no test in the targets \(reconciliation.scope.manifest) bounds, so there was nothing to reconcile against"]
        }
        guard counts.missing > 0 || counts.duplicated > 0 || counts.linesLost > 0 || crash != nil else {
            return ["inventory: \(counts.expected) declared, \(counts.ran) reported\(Self.qualification(reconciliation))"]
        }
        var clauses = [crash?.inventoryClause].compactMap(\.self)
        if counts.missing > 0 {
            let named = reconciliation.missing.map(\.enumerated) + reconciliation.shortfalls.map(\.function)
            clauses.append("\(counts.missing) never reported: \(listing(named))")
        }
        if counts.linesLost > 0 {
            let named = reconciliation.lost.map(\.enumerated) + reconciliation.lostByCount.map(\.function)
            clauses.append("\(counts.linesLost) result line\(counts.linesLost == 1 ? "" : "s") lost, the tests passing by their suite and run summaries: \(listing(named))")
        }
        if counts.duplicated > 0 {
            clauses.append("\(counts.duplicated) reported more than once: \(listing(reconciliation.duplicated.map(\.test.enumerated), of: counts.duplicated))")
        }
        var lines = ["inventory: \(counts.expected) declared, \(counts.ran) reported\(Self.qualification(reconciliation)) — \(clauses.joined(separator: " · "))"]
        lines.append(contentsOf: reconciliation.shortfalls.prefix(listedNames).map { "  \($0.function): \($0.sentence), by count alone" })
        lines.append(contentsOf: reconciliation.lostByCount.prefix(listedNames).map { "  \($0.function): \($0.lostSentence), by count alone" })
        return lines
    }

    /// The undecided, excluded and outside-scope counts the `N declared, N reported` line owes, in both the healthy and the residue branch.
    static func qualification(_ reconciliation: RunReconciliation) -> String {
        var clauses: [String] = []
        if !reconciliation.undecided.isEmpty {
            let count = reconciliation.undecided.count
            clauses.append("\(count) conditional test\(count == 1 ? "" : "s") reported nothing, counted in neither direction: \(listing(reconciliation.undecided.map(\.enumerated)))")
        }
        if !reconciliation.excluded.isEmpty {
            clauses.append("\(reconciliation.excluded.count) excluded by XCTFail")
        }
        if reconciliation.counts.skipped > 0 {
            clauses.append("\(reconciliation.counts.skipped) skipped by the runner, not run: \(listing(reconciliation.skipped.map(\.enumerated), of: reconciliation.counts.skipped))")
        }
        if !reconciliation.compiledOut.isEmpty {
            let count = reconciliation.compiledOut.count
            clauses.append("\(count) more \(count == 1 ? "sits" : "sit") under an #if this platform does not compile, not run here: \(listing(reconciliation.compiledOut.map(\.enumerated)))")
        }
        if !reconciliation.outsideScope.isEmpty {
            clauses.append("\(reconciliation.outsideScope.count) outside this run's scope")
        }
        // An XCTest ending no declaration claimed ran beside the reported count rather than inside it, so it is named here:
        // left unsaid, a case whose tests the index never declared runs and the counts line still reads as if it had not.
        // A Swift Testing name that claimed nothing is left to the notes.
        let unclaimed = reconciliation.unclaimed.filter { TestIdentifier.xctestLogName($0) != nil }
        if !unclaimed.isEmpty {
            clauses.append("\(unclaimed.count) more XCTest ending\(unclaimed.count == 1 ? "" : "s") no declared test claims: \(listing(unclaimed))")
        }
        guard !clauses.isEmpty else {
            return ""
        }
        return " (\(clauses.joined(separator: " · ")))"
    }

    /// Up to ``listedNames`` of `names`, and how many more there are of `total`.
    static func listing(_ names: [String], of total: Int? = nil) -> String {
        let total = max(total ?? names.count, names.count)
        let shown = names.prefix(listedNames)
        let rest = total - shown.count
        guard !shown.isEmpty else {
            return "none by name"
        }
        return shown.joined(separator: ", ") + (rest > 0 ? ", +\(rest) more" : "")
    }

    /// What the detached check hands back, when it gets there before the budget does.
    ///
    /// Unchecked because the semaphore is the ordering: the write happens before the signal and the read only after a successful wait.
    final class CheckBox: @unchecked Sendable {
        private(set) var value: RunInventoryCheck?

        func store(_ check: RunInventoryCheck) {
            value = check
        }
    }
}
