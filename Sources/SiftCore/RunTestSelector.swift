//
// Copyright © Agulhas Labs
//

import Foundation

/// The tests a wrapped run was told to run by name — `swift test --filter …` or `xcodebuild -only-testing:…` — and whether its log shows that none of them ran.
///
/// **A selector that matched nothing is not a pass, and neither tool says so.** `swift test --filter` prints `warning: No matching test cases were run` and exits 0; `xcodebuild -only-testing:` naming a Swift Testing function without its trailing `()` executes 0 tests and still prints `** TEST SUCCEEDED **`. Passed through as they stand, both read as a green run — and a negative gate run that way reports "passes with the fix set aside" when nothing ran at all, the most dangerous false green there is.
///
/// **So that run answers `✘` and exits ``exitCode``, the one code `sift run` does not pass through.** Not 1, which is `swift test`'s test failure, and not 65, which is `xcodebuild`'s: a negative gate expects its command to fail, so a "nothing ran" spelled like a failure would read as "the test failed without the fix", the same false gate in reverse.
///
/// Only a run that exited 0 is judged. A nonzero exit already fails on its own terms, and a build that broke before any test started must keep saying that rather than be reworded as a selector that matched nothing.
///
/// **A selected run whose build failed before any test process started is the other run of none, and gets a code of its own.** Passed through, its exit is 1 under `swift test`, the same code as a test that failed, so a negative gate read a compile error as the proof it was after. It answers `✘ … did not build — no test ran` and exits ``didNotBuildExitCode``; an unselected build failure still passes its exit code through.
///
/// **One `--filter` of several that matched nothing is the same false green, with the others' tests standing over it**, and gets the same `✘` and the same ``exitCode``, its pattern named (``unmatchedFilters(_:exitCode:)``).
///
/// **And only on positive evidence of zero.** A log that is merely silent about its tests is not one that ran none: `xcodebuild -quiet` prints no test line and no verdict on a clean pass, and `swift test --parallel` prints only `[1/1] Testing …` progress for an XCTest it ran and passed. Either run keeps the answer it had before this reading existed, and its exit code.
public struct RunTestSelector: Sendable, Equatable {
    /// Each selector as the command line spelled it, `--filter <pattern>` or `-only-testing:<identifier>`, in argv order.
    public let spellings: [String]
    /// Each `swift test --filter` pattern, in argv order, beside its entry in ``spellings``; empty for an `xcodebuild` selector.
    let patterns: [String]
    /// The `-only-testing` identifiers that name a test below a bundle and end without `()`, the spelling a Swift Testing function is not matched by.
    let unparenthesised: [String]
    /// Whether the run is an `xcodebuild` without `-quiet`, which prints a line for every test it runs, serial or parallel, so its printed success banner over no such line is a zero rather than silence.
    let printsEveryTest: Bool

    /// What `sift run` exits with when a selector matched nothing: a code neither `swift test` (1) nor `xcodebuild` (65, and the rest of the sysexits range it uses) returns for a test failure.
    public static let exitCode: Int32 = 4

    /// What `sift run` exits with when a selected run's build failed before any test process started: apart from ``exitCode``, since a build that broke is not a selector that matched nothing, and apart from 1 and 65 for the reason ``exitCode`` is.
    public static let didNotBuildExitCode: Int32 = 5
}

public extension RunTestSelector {
    /// The selectors a run of `arguments` carries, or `nil` for a command that names no test to run or runs none.
    ///
    /// An `xcodebuild` selector counts only under an action that executes tests, `test` or `test-without-building`: `build-for-testing -only-testing:…` builds and runs nothing, so its zero is no evidence about the selector. An action argv leaves in doubt is not judged either.
    static func named(in arguments: [String]) -> RunTestSelector? {
        let kind = RunCommandKind.recognize(arguments)
        if case .xcodebuild = kind, !testingActions.contains(RunVerdict.Contract.xcodebuildAction(of: arguments) ?? "") {
            return nil
        }
        var spellings: [String] = []
        var identifiers: [String] = []
        var patterns: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index) < arguments.endIndex ? arguments[arguments.index(after: index)] : nil
            switch kind {
            case .swiftTest where argument == "--filter":
                if let next {
                    spellings.append("--filter \(next)")
                    patterns.append(next)
                    index = arguments.index(after: index)
                }
            case .swiftTest where argument.hasPrefix("--filter="):
                let pattern = String(argument.dropFirst("--filter=".count))
                spellings.append("--filter \(pattern)")
                patterns.append(pattern)
            case .xcodebuild where argument == "-only-testing":
                if let next {
                    spellings.append("-only-testing:\(next)")
                    identifiers.append(next)
                    index = arguments.index(after: index)
                }
            case .xcodebuild where argument.hasPrefix("-only-testing:"):
                spellings.append(argument)
                identifiers.append(String(argument.dropFirst("-only-testing:".count)))
            default:
                break
            }
            index = arguments.index(after: index)
        }
        guard !spellings.isEmpty else {
            return nil
        }
        // A bare bundle name selects a whole bundle, where a missing `()` means nothing; below it, the last
        // component may be a Swift Testing function, and whether it is cannot be told from the text.
        let unparenthesised = identifiers.filter { identifier in
            let components = identifier.split(separator: "/")
            return components.count > 1 && components.last?.hasSuffix(")") == false
        }
        let printsEveryTest = kind == .xcodebuild && !RunVerdict.Contract.isQuietXcodebuild(arguments)
        return RunTestSelector(spellings: spellings, patterns: patterns, unparenthesised: unparenthesised, printsEveryTest: printsEveryTest)
    }

    /// Whether a run that exited `exitCode` with this `report` executed no test at all.
    ///
    /// Judged only on positive evidence of zero, never on silence: SwiftPM's own `No matching test cases were run`, closing counts that every test process printed and that all say 0 tests, `xcodebuild`'s parallel testing starting a suite on a runner (`Test suite '…' started on '…'`) with no `Test case '…' on '…'` line anywhere, or an `xcodebuild` run without `-quiet` whose verdict is the success banner it printed (never one inferred from its exit code) and whose log shows no test ran (``showsATestRan(_:)``) — without `-quiet`, `xcodebuild` prints a line for every test it runs, serial or parallel, so its banner over none is a run of none, the spelling a Swift Testing function named without its `()` gets under parallel testing. No test may have started or ended, none may have run under `xcodebuild`'s parallel testing, and no closing count may say anything but 0. An unreadable count is never read as 0, and a log with no count at all is undecided rather than empty. Under `swift test --parallel` a Swift Testing `Test run with 0 tests` is not evidence either, because SwiftPM prints no XCTest count for the tests it ran in parallel (``RunReport/parallelSwiftTest``).
    func matchedNothing(_ report: RunReport, exitCode: Int32) -> Bool {
        guard exitCode == 0, report.testFailures.isEmpty, report.errors.isEmpty,
              report.testOutcomes.isEmpty, report.testOutcomes.parallelLines == 0
        else {
            return false
        }
        let everyCountIsZero = Self.closingCounts(of: report).allSatisfy { $0 == 0 }
        guard everyCountIsZero else {
            return false
        }
        if report.warnings.contains(where: { $0.message == Self.noMatchWarning }) {
            return true
        }
        if report.testOutcomes.parallelSuiteStarts > 0 {
            return true
        }
        if printsEveryTest, let verdict = report.verdict, verdict.state == .succeeded, verdict.line != nil,
           !verdict.inferredFromExitCode, verdict.answersTheInvokedCommand, !Self.showsATestRan(report)
        {
            return true
        }
        return !report.parallelSwiftTest && report.testProcessClosings > 0
            && report.testProcessClosings >= report.testProcessOpenings
    }

    /// The spelling of each `--filter` that matched none of the tests a run that exited `exitCode` with this `report` ran, where others did; empty where every one matched, and where the run cannot say which tests it ran.
    ///
    /// SwiftPM matches a pattern as a regular expression against a substring of each test's identifier and runs a test any pattern matches, so one pattern that matched nothing leaves the run's tests, its verdict and its exit code exactly as they would be without it. The identifiers matched against are every test function the run's event stream declared, verbatim with its `/File.swift:line:column`, which is part of what a pattern can match, and each XCTest the console named, as `Module.Class/method`. Neither a suite's id nor an XCTest class alone is among them: SwiftPM runs no test for a pattern only those match (`AlphaSuite$`, `AlphaTests$`), so counting them would hide the very pattern this names.
    ///
    /// Judged as ``matchedNothing(_:exitCode:)`` is, on positive evidence only: a run of more than one `--filter` (a single one that matched nothing ran nothing, which is that reading's), that exited 0 with no failure and no error, not under `--parallel` (which prints no line for an XCTest it ran), that shows a test ran, whose Swift Testing tests the event stream declared, and whose every XCTest name reads as `-[Module.Class method]`. **A class the console prints without its module is not judged**: an `@objc(RenamedObjCTests)` class logs as `-[RenamedObjCTests testRenamed]` while SwiftPM matches its Swift name, `Module.SwiftNamedTests/testRenamed`, which nothing in the log spells, and a real filter must never be named unmatched. A pattern that does not compile is never named. A run that ran nothing is ``matchedNothing(_:exitCode:)``'s.
    func unmatchedFilters(_ report: RunReport, exitCode: Int32) -> [String] {
        guard patterns.count > 1, exitCode == 0, report.testFailures.isEmpty, report.errors.isEmpty,
              !report.parallelSwiftTest, Self.showsATestRan(report)
        else {
            return []
        }
        var identifiers = report.streamedTestIDs ?? []
        if !report.testOutcomes.swiftTestingNames.isEmpty, identifiers.isEmpty {
            return []
        }
        for name in report.testOutcomes.leavingOutSwiftTesting.names {
            guard let (type, method) = TestIdentifier.xctestLogName(name), type.contains(".") else {
                return []
            }
            identifiers.insert("\(type)/\(method)")
        }
        return zip(spellings, patterns).compactMap { spelling, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            let matched = identifiers.contains { identifier in
                expression.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)) != nil
            }
            return matched ? nil : spelling
        }
    }

    /// Whether a run that exited `exitCode` with this `report` failed to build before any test process started.
    ///
    /// Judged on positive evidence of a build failure, never on silence: a nonzero exit, no test process opened, no test started, ended or failed, and an error that is a compiler's, at a file and line, or the linker's, an `Undefined symbols` block or `linker command failed` — or a compiler crash (``RunReport/compilerCrash``), whose one `error:`-shaped line the crash reader claims, or `xcodebuild`'s own `Testing cancelled because the build failed.`, for a build failure whose compiler error carries no `file:line` at all (a signing failure, a missing build input file), which still exits `65`/`1` as if a test had failed. Any other error, a wrong scheme or a destination `xcodebuild` could not find or an `xcrun` that found no `xctest`, is a command that failed before it built rather than a build that failed, and keeps its exit code.
    ///
    /// **A `Failing tests:` block vetoes all of it.** A `-quiet` run's own Swift Testing failure line (`FooTests.swift:8: error: …`) reads exactly like a compiler error at a file and line, but `xcodebuild` only ever prints `Failing tests:` once a named test actually ran and failed — so its presence means the build succeeded and a test failed, whatever `errors` and ``cancelledForBuildFailure`` say.
    func didNotBuild(_ report: RunReport, exitCode: Int32) -> Bool {
        Self.buildFailedFirst(report, exitCode: exitCode)
    }

    /// ``didNotBuild(_:exitCode:)``'s evidence, which no selector enters into: what lets any test run's answer say no test process started, filtered or not.
    static func buildFailedFirst(_ report: RunReport, exitCode: Int32) -> Bool {
        guard exitCode != 0, report.testFailures.isEmpty, report.testProcessOpenings == 0,
              report.testOutcomes.parallelSuiteStarts == 0, !showsATestRan(report),
              !report.namedFailingTests
        else {
            return false
        }
        if report.cancelledForBuildFailure || report.compilerCrash != nil {
            return true
        }
        return report.errors.contains { error in
            (error.path != nil && error.line != nil) || error.message.hasPrefix("Undefined symbols")
                || error.message.hasPrefix("linker command failed")
        }
    }

    /// The code `sift run` exits with for a run of this selector where it is not the wrapped command's own — ``exitCode`` for a selector that matched nothing, ``didNotBuildExitCode`` for a build that failed before any test ran — or `nil` for a run whose exit code passes through.
    func ownExitCode(_ report: RunReport, exitCode: Int32) -> Int32? {
        if matchedNothing(report, exitCode: exitCode) {
            return Self.exitCode
        }
        if didNotBuild(report, exitCode: exitCode) {
            return Self.didNotBuildExitCode
        }
        if !unmatchedFilters(report, exitCode: exitCode).isEmpty {
            return Self.exitCode
        }
        return nil
    }

    /// The `--filter` pattern of each selector that matched no test in a run that exited `exitCode` with this `report`: every pattern where the run ran nothing (``matchedNothing(_:exitCode:)``), the ones ``unmatchedFilters(_:exitCode:)`` names where others ran; empty otherwise, and for an `xcodebuild` run, which has no patterns.
    func unmatchedPatterns(_ report: RunReport, exitCode: Int32) -> [String] {
        if matchedNothing(report, exitCode: exitCode) {
            return patterns
        }
        let unmatched = Set(unmatchedFilters(report, exitCode: exitCode))
        return zip(spellings, patterns).filter { unmatched.contains($0.0) }.map(\.1)
    }

    /// Whether `report` shows that any test ran at all: a test's own start or end line, a parallel runner's `Test case '…' on '…'`, or a closing count above 0.
    ///
    /// The other half of ``matchedNothing(_:exitCode:)``, and deliberately not its negation: a log silent about its tests is neither evidence of zero nor evidence that one ran, so a selected run whose log is silent keeps its exit code and is never recorded as a proof (``RunOutcome/provedGreen(testBundles:selector:)``).
    static func showsATestRan(_ report: RunReport) -> Bool {
        !report.testOutcomes.isEmpty || report.testOutcomes.parallelLines > 0
            || closingCounts(of: report).contains { ($0 ?? 0) > 0 }
    }

    /// The test count each closing line in `report` states, in order — `nil` for a closing line whose count cannot be read — and nothing for a summary line that is not a closing count.
    private static func closingCounts(of report: RunReport) -> [Int?] {
        report.summaryLines.compactMap { line -> Int?? in
            let undecorated = String(RunOutputFilter.undecorated(line))
            if undecorated.hasPrefix("Test run with ") {
                return .some(RunTestTally.parse(undecorated)?.tests)
            }
            if line.hasPrefix("Executed ") {
                return .some(RunOutputFilter.ExecutedCounts(line: line)?.tests)
            }
            return nil
        }
    }

    /// Whether an unselected `swift test` of a package whose manifest declares test targets exited 0 and executed no test at all, the same false green as a selector that matched nothing with no selector to name.
    ///
    /// Judged on the positive evidence ``matchedNothing(_:exitCode:)`` takes from closing counts: every test process that opened closed, every closing count reads 0, and no test started, ended, failed or ran in parallel. `testBundles` is ``RunTestBundles/declaredByManifest(_:)`` only for a `swift test` no option narrows, so a filtered run, another package and an `xcodebuild` run are never judged here.
    static func executedNothing(_ report: RunReport, exitCode: Int32, testBundles: RunTestBundles) -> Bool {
        guard (testBundles.count ?? 0) > 0, exitCode == 0, report.testFailures.isEmpty, report.errors.isEmpty,
              report.testOutcomes.isEmpty, report.testOutcomes.parallelLines == 0, !report.parallelSwiftTest,
              closingCounts(of: report).allSatisfy({ $0 == 0 })
        else {
            return false
        }
        return report.testProcessClosings > 0 && report.testProcessClosings >= report.testProcessOpenings
    }

    /// The headline for an unselected run that executed no test in the `declared` test targets: `✘`, that nothing ran, and the exit code that says so.
    static func executedNothingHeadline(label: String, declared: Int) -> String {
        "✘ \(label) — nothing ran: no test executed, though the package declares \(targets(declared)) (the command exited 0; sift run exits \(exitCode))"
    }

    /// The head of the `totals:` line for the same run, worded as its headline is.
    static func executedNothingTotalsHead(declared: Int) -> String {
        "✘ nothing ran — no test executed in the \(targets(declared)) the package declares"
    }

    /// `declared` with its noun, singular or plural.
    private static func targets(_ declared: Int) -> String {
        declared == 1 ? "1 test target" : "\(declared) test targets"
    }

    /// The headline for a run whose selector matched nothing: `✘`, the selector, that nothing ran, and the exit code that says so.
    func headline(label: String) -> String {
        let named = spellings.joined(separator: ", ")
        var line = "✘ \(label) — nothing ran: no test matched \(named) (the command exited 0; sift run exits \(Self.exitCode))"
        if let first = unparenthesised.first {
            line += " — if it names a Swift Testing function, spell it with the trailing (): -only-testing:\(first)()"
        }
        return line
    }

    /// The head of the `totals:` line for the same run, worded so a gate reading only that line sees the same verdict.
    var totalsHead: String {
        "✘ nothing ran — no test matched \(spellings.joined(separator: ", "))"
    }

    /// The headline for a run where the `unmatched` filters, and not the others, matched no test: `✘`, each of them, how many of the filters they are, and the exit code that says so.
    func headline(label: String, unmatched: [String]) -> String {
        "✘ \(label) — \(unmatchedClause(unmatched)) (the command exited 0; sift run exits \(Self.exitCode))"
    }

    /// The head of the `totals:` line for the same run, worded as its headline is.
    func totalsHead(unmatched: [String]) -> String {
        "✘ \(unmatchedClause(unmatched))"
    }

    /// `no test matched` and each of `unmatched`, then how many of this selector's filters they are.
    private func unmatchedClause(_ unmatched: [String]) -> String {
        "no test matched \(unmatched.joined(separator: ", ")) — \(unmatched.count) of \(spellings.count) filters"
    }

    /// The headline for a selected run whose build failed before any test ran: `✘`, that it did not build, and the exit code that says so.
    static func didNotBuildHeadline(label: String, exitCode: Int32) -> String {
        "✘ \(label) — did not build — no test ran (the command exited \(exitCode); sift run exits \(didNotBuildExitCode))"
    }

    /// The head of the `totals:` line for the same run, worded as its headline is.
    static var didNotBuildTotalsHead: String {
        "✘ did not build — no test ran"
    }

    /// The `xcodebuild` actions that execute tests, the only ones whose selector can be said to have matched nothing.
    private static let testingActions: Set<String> = ["test", "test-without-building"]

    /// What SwiftPM prints, as a warning, when a `--filter` matched no test.
    private static var noMatchWarning: String {
        "No matching test cases were run"
    }
}
