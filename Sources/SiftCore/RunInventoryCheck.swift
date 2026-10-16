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

    /// How long building or bringing the index up to date and reconciling may take before the check is skipped rather than waited on.
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
    /// The package a run of `arguments` tests, where the inventory bounds the run: an unnarrowed, serial `swift test` that reported at least one test, of the package at or above the directory `--package-path`, `-C` or `--chdir` names, or else `workingDirectory`; or an unnarrowed, serial `xcodebuild` test run of the `<Name>-Package` scheme of the package in `workingDirectory` itself (``xcodebuildBounds(_:report:workingDirectory:executedNothing:)``).
    ///
    /// The bound is `--against`'s own — that package's manifest's test targets — so anything that runs another set is out of it: a filtered or skipped run, a `--parallel` run whose log names only some of its tests, and a run with no manifest at or above its directory or one naming its directory through a variable say nothing, and any other unnarrowed `xcodebuild` test run, whose set is its scheme's, says why it was not checked (``unboundedXcodebuild(by:report:workingDirectory:executedNothing:)``).
    ///
    /// - Parameter executedNothing: Whether the run exited 0 having executed no test in a package that declares test targets (``RunTestSelector/executedNothing(_:exitCode:testBundles:)``): it reported none, and is bounded all the same, since the declared count is what says how much it missed.
    static func testedPackage(by arguments: [String], report: RunReport, workingDirectory: URL, executedNothing: Bool = false) -> URL? {
        if RunCommandKind.recognize(arguments) == .xcodebuild {
            return xcodebuildBounds(arguments, report: report, workingDirectory: workingDirectory, executedNothing: executedNothing) ? workingDirectory : nil
        }
        guard bounds(arguments, report: report, executedNothing: executedNothing),
              let directory = RunCommandKind.builtDirectory(of: arguments, from: workingDirectory.path)
        else {
            return nil
        }
        return packageRoot(above: URL(fileURLWithPath: directory, isDirectory: true)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The unchecked form of the line for a run the inventory would bound but whose package directory is spelled through a variable, so there is no package to take the declared tests from; `nil` for every other run.
    ///
    /// Saying nothing there would read as a run that was checked and found whole.
    static func unresolvedPackage(by arguments: [String], report: RunReport, workingDirectory: URL, executedNothing: Bool = false) -> RunInventoryCheck? {
        guard bounds(arguments, report: report, executedNothing: executedNothing),
              RunCommandKind.builtDirectory(of: arguments, from: workingDirectory.path) == nil
        else {
            return nil
        }
        return .skipped("the package directory is spelled through a variable, so the package whose tests it declares cannot be told")
    }

    /// The unchecked line a run carries where ``testedPackage(by:report:workingDirectory:executedNothing:)`` finds no package to reconcile against: ``unresolvedPackage(by:report:workingDirectory:executedNothing:)``'s, or else ``unboundedXcodebuild(by:report:workingDirectory:executedNothing:)``'s, and `nil` for a run that says nothing.
    static func unchecked(by arguments: [String], report: RunReport, workingDirectory: URL, executedNothing: Bool = false) -> RunInventoryCheck? {
        unresolvedPackage(by: arguments, report: report, workingDirectory: workingDirectory, executedNothing: executedNothing)
            ?? unboundedXcodebuild(by: arguments, report: report, workingDirectory: workingDirectory, executedNothing: executedNothing)
    }

    /// The unchecked form of the line for an unnarrowed `xcodebuild` test run that reported a test, or executed none, and that no package manifest bounds; `nil` for every other run, a narrowed one included, which says nothing as a filtered `swift test` does.
    ///
    /// Saying nothing there would read as a run that was checked and found whole. A run under `xcodebuild`'s parallel testing, or under `-quiet` with no build error, says why its own way instead: the first names its tests in lines that are not read as outcomes, and the second prints no line for a test that passed, so reconciling either would name tests that ran as never reported.
    static func unboundedXcodebuild(by arguments: [String], report: RunReport, workingDirectory: URL, executedNothing: Bool = false) -> RunInventoryCheck? {
        let quiet = RunVerdict.Contract.isQuietXcodebuild(arguments)
        guard RunCommandKind.recognize(arguments) == .xcodebuild,
              RunCommandKind.executesTests(arguments),
              !report.testOutcomes.isEmpty || executedNothing || runsInParallel(report) || (quiet && report.errors.isEmpty),
              !narrowsXcodebuild(arguments),
              !xcodebuildBounds(arguments, report: report, workingDirectory: workingDirectory, executedNothing: executedNothing)
        else {
            return nil
        }
        if runsInParallel(report) {
            return .skipped("xcodebuild's parallel testing names its tests in lines this does not read as outcomes")
        }
        if quiet {
            return .skipped("xcodebuild -quiet prints no line for a test that passed, so there is no list of tests to reconcile")
        }
        if let scheme = scheme(in: arguments), let file = schemeFile(named: scheme, in: workingDirectory) {
            return .skipped("\(file) replaces the scheme Xcode generates over the package's test targets, so no package manifest bounds the tests it runs")
        }
        return .skipped("an xcodebuild scheme runs the test targets it names, which no package manifest bounds")
    }

    /// Reconciles `outcomes` against the index at `repositoryRoot`, inside the manifest of `package` (the repository's root where it is `nil`), brought up to date first as `--against` does; a checkout with no index yet has one built inside the same budget.
    ///
    /// - Parameter executedNothing: Whether the run executed no test, as ``testedPackage(by:report:workingDirectory:executedNothing:)`` takes it: its empty outcomes reconcile as zero reported, so the line names every declared test that never reported.
    static func check(_ outcomes: RunTestOutcomes, loggedAt logURL: URL?, repositoryRoot: URL, package: URL? = nil, budget: TimeInterval = freshenBudget, executedNothing: Bool = false) -> RunInventoryCheck {
        let root = CanonicalPath.of(repositoryRoot.path)
        let packagePath = package.map { CanonicalPath.of($0.path) } ?? root
        guard packagePath == root || packagePath.hasPrefix(root + "/") else {
            return .skipped("the package at \(packagePath) lies outside the repository at \(root), whose index this reads")
        }
        let packageDirectory = String(packagePath.dropFirst(min(packagePath.count, root.count + 1)))
        let box = CheckBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let check: RunInventoryCheck
            do {
                let engine = try SiftEngine(directory: repositoryRoot)
                try await engine.ensureFresh()
                check = try .reconciled(engine.reconcileRun(outcomes, loggedAt: logURL, packageDirectory: packageDirectory, executedNothing: executedNothing))
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
    /// Whether the inventory bounds the run of `arguments`: an unnarrowed, serial `swift test` that reported a test, or executed none in a package that declares some.
    static func bounds(_ arguments: [String], report: RunReport, executedNothing: Bool) -> Bool {
        let narrowing = RunTestBundles.narrowingOptions + ["--parallel"]
        return RunCommandKind.recognize(arguments) == .swiftTest
            && (!report.testOutcomes.isEmpty || executedNothing)
            && !report.parallelSwiftTest
            && !arguments.contains(where: { argument in narrowing.contains { argument == $0 || argument.hasPrefix($0 + "=") } })
    }

    /// The `xcodebuild` options that narrow a test run to part of its scheme, each written `-flag value` or `-flag:value`.
    static let xcodebuildNarrowingOptions = ["-only-testing", "-skip-testing", "-testPlan", "-only-test-configuration", "-skip-test-configuration"]

    /// Whether any of `arguments` narrows an `xcodebuild` test run to part of its scheme or test plan.
    static func narrowsXcodebuild(_ arguments: [String]) -> Bool {
        arguments.contains { argument in xcodebuildNarrowingOptions.contains { argument == $0 || argument.hasPrefix($0 + ":") } }
    }

    /// Whether the run printed the lines `xcodebuild`'s parallel testing reports in, which name tests without being read as their outcomes.
    static func runsInParallel(_ report: RunReport) -> Bool {
        report.testOutcomes.parallelLines > 0 || report.testOutcomes.parallelSuiteStarts > 0
    }

    /// Whether the inventory bounds the `xcodebuild` run of `arguments` from `workingDirectory` exactly as it bounds an unnarrowed `swift test` of the package there.
    ///
    /// That holds only for the scheme Xcode generates over a package's every test target, `<Name>-Package` with the name the manifest writes and no scheme file of that name kept under `.swiftpm/xcode` in its place (``schemeFile(named:in:)``), run serially, unnarrowed and without `-quiet`, and only where `xcodebuild` reads that manifest: no `-project` or `-workspace` names another, and no `.xcodeproj` or `.xcworkspace` beside the `Package.swift` takes its place. A package with a single product gets no `-Package` scheme, and its product's scheme is read as unbounded rather than guessed at.
    static func xcodebuildBounds(_ arguments: [String], report: RunReport, workingDirectory: URL, executedNothing: Bool) -> Bool {
        guard RunCommandKind.recognize(arguments) == .xcodebuild,
              RunCommandKind.executesTests(arguments),
              !report.testOutcomes.isEmpty || executedNothing,
              !runsInParallel(report),
              !RunVerdict.Contract.isQuietXcodebuild(arguments),
              !narrowsXcodebuild(arguments),
              !arguments.contains(where: { argument in ["-project", "-workspace"].contains { argument == $0 || argument.hasPrefix($0 + "=") } }),
              let scheme = scheme(in: arguments),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: workingDirectory.path),
              entries.contains("Package.swift"),
              !entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }),
              let name = SwiftPMManifest.packageName(inPackageAt: workingDirectory)
        else {
            return false
        }
        return scheme == name + "-Package" && schemeFile(named: scheme, in: workingDirectory) == nil
    }

    /// The scheme `-scheme` names in `arguments`, the last where it is given twice.
    static func scheme(in arguments: [String]) -> String? {
        guard let flag = arguments.lastIndex(of: "-scheme"), flag + 1 < arguments.count else {
            return nil
        }
        return arguments[flag + 1]
    }

    /// The package-relative path of a scheme file named `scheme` that the package at `package` keeps, shared or any one user's, or `nil` where it keeps none.
    ///
    /// Xcode generates a package's schemes only where no such file exists, so a kept file decides which test targets the scheme runs, and can skip any of them.
    static func schemeFile(named scheme: String, in package: URL) -> String? {
        let xcode = ".swiftpm/xcode"
        let file = "xcschemes/\(scheme).xcscheme"
        let users = (try? FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent(xcode + "/xcuserdata").path)) ?? []
        let candidates = ["\(xcode)/xcshareddata/\(file)"] + users.filter { $0.hasSuffix(".xcuserdatad") }.sorted().map { "\(xcode)/xcuserdata/\($0)/\(file)" }
        return candidates.first { FileManager.default.fileExists(atPath: package.appendingPathComponent($0).path) }
    }

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
