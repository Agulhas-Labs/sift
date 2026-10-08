//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer to `run --without`: for every test the filter named, whether it fails without the change and passes with it.
///
/// **One line per test, and the ones that break the claim first** — a test that passes without the change pins nothing, and one that fails both ways is not pinning it either — because a caller scanning for the exception should meet it before the confirmations. The headline counts only the tests that failed by assertion without the change and passed with it.
///
/// **A run that never reached its tests is said for what it was, and no more.** Tests that did not *compile* without the change are evidence they need it, not an assertion that fails without it, and get a headline of their own — claimed only where a compiler error lands in a file that imports a test framework. Any other error before a test ran, a wrong scheme or a source file that did not build, is the command failing before it ran tests, quoted, and nothing more.
///
/// **Proven means one thing**, and ``proven`` is what the exit code is made from: every named test failed without the change and passed with it, both runs on the one commit — counting only the tests the listing names, since one the change never wrote, passing both ways, is folded away as expected. Everything else — a test that pins nothing, no test the change wrote running at all, one that fails both ways, a run that reported no test, a suite that did not compile, HEAD moving under the run — is not proven, however promising it reads.
public struct RunWithoutAnswer {
    public let pathspecs: String
    public let without: RunOutcome
    public let with: RunOutcome
    public let restored: SetAside.Restored
    public let workingDirectory: URL
    /// The repository the run was made in, which is what the record's paths are relative to.
    public let repositoryRoot: URL
    /// Processes the run without the change left running, which were ended before the changes went back.
    public let stragglers: Int
    /// The commit HEAD names since the run, when it moved away from the one the changes were set aside to.
    public let headNow: String?
    /// Whether the command retries a failing test, so a name that finishes more than once is one test counted by its last attempt.
    public let retriesFailures: Bool
    /// Whether the watcher had stopped before the changes were back — for part of the run, a kill would have left them out of the tree.
    public let watcherLost: Bool
    /// Where the run without the change built, as an absolute path — named in the receipt, from the working directory, with how to remove it when the run left it in place.
    public let buildDirectory: String?
    /// ``buildDirectory``'s size on disk, in bytes, measured before it was removed; `nil` when nothing was built there.
    public let buildDirectorySize: Int64?
    /// Whether ``buildDirectory`` was gone once the run ended, read off the disk: the receipt then says it was removed, and otherwise names it and how to remove it.
    public let buildDirectoryRemoved: Bool
    /// The tests the change itself adds or edits, as bare identifiers (``ChangedTests``); `nil` where that could not be read, which folds nothing.
    ///
    /// A test the change never wrote passing both ways is the expected case rather than a finding, so those are counted into one line instead of listed. `nil` and an empty set are different answers: unread lists every test as it always did, and read-and-empty folds every untouched one.
    public let changedTests: Set<String>?
    /// The selector `arguments` named, the same one a plain `sift run` reads to tell a build failure from a test failure; `nil` where nothing was named.
    ///
    /// Read by ``runLines(_:named:)`` so each run's own line calls a build failure what a plain `sift run` would: without it, a run without the change that failed to build reads as an ordinary `✘`, indistinguishable from a test that ran and failed — which is the false proof `--without` exists to rule out.
    public let selector: RunTestSelector?

    /// The line an answer carries when the watcher had stopped while the changes were out of the tree.
    public static var watcherLostLine: String {
        "  ⚠ the watcher that puts the changes back if this process is killed had stopped before they were back — they are back now, but for part of the run a kill would have left them out of the tree until `sift run --restore`"
    }

    /// How an answer, or the notice given before the runs, names the paths a set-aside takes out of the tree outright; `nil` where it takes out none.
    ///
    /// At most three are named, because the reader needs the shape of what happened rather than the list — `git status` has the list.
    public static func newFilesClause(_ record: SetAsideRecord) -> String? {
        let files = record.newFiles
        guard let first = files.first else {
            return nil
        }
        let named = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        // Under `--since` the file is in HEAD — it is what the range added — so naming HEAD here would tell
        // the reader the file is missing from a commit it is actually in.
        let placedIn = record.since.map { "in \(String($0.prefix(10)))" } ?? "in HEAD"
        guard files.count > 1 else {
            return "\(first) is not \(placedIn), so setting it aside removed it"
        }
        return "\(named) are not \(placedIn), so setting them aside removed them"
    }

    /// The notice given once the run without the change has ended, or `nil` where that run built and ran tests, because then it can show a failing assertion and the notice's claim that it cannot would be false.
    public static func newFilesNotice(_ record: SetAsideRecord, withoutBuilt: Bool) -> String? {
        guard !withoutBuilt, let clause = newFilesClause(record) else {
            return nil
        }
        return "◇ sift run --without: \(clause) — a test that names what it declares cannot build without the change, so this run can show only that, never a failing assertion — to prove such a fix, neutralise its guarding line: sift run --without-line <file>:<line> -- <the same command>"
    }

    /// How many test lines are listed before the rest are counted instead.
    static let testLineCap = 40
    /// How many compile errors of the run without the change are quoted — evidence, not a worklist.
    static let withoutErrorCap = 3
    /// How many of the run with the change — the caller's own tree, and so the errors they have to fix.
    static let withErrorCap = 10

    public init(
        pathspecs: String,
        without: RunOutcome,
        with: RunOutcome,
        restored: SetAside.Restored,
        workingDirectory: URL,
        repositoryRoot: URL,
        stragglers: Int = 0,
        headNow: String? = nil,
        retriesFailures: Bool = false,
        watcherLost: Bool = false,
        buildDirectory: String? = nil,
        buildDirectorySize: Int64? = nil,
        buildDirectoryRemoved: Bool = false,
        changedTests: Set<String>? = nil,
        selector: RunTestSelector? = nil
    ) {
        self.pathspecs = pathspecs
        self.without = without
        self.with = with
        self.restored = restored
        self.workingDirectory = workingDirectory
        self.repositoryRoot = repositoryRoot
        self.stragglers = stragglers
        self.headNow = headNow
        self.retriesFailures = retriesFailures
        self.watcherLost = watcherLost
        self.buildDirectory = buildDirectory
        self.buildDirectorySize = buildDirectorySize
        self.buildDirectoryRemoved = buildDirectoryRemoved
        self.changedTests = changedTests
        self.selector = selector
    }
}

public extension RunWithoutAnswer {
    func render() -> RunOutcome.Answer {
        let paths = RunAnswerPaths.read(in: workingDirectory)
        let tests = testLines()
        var lines = [headline(tests)]
        if let removed = newFilesLine() {
            lines.append(removed)
        }
        if let stop = stopWithout {
            lines.append(contentsOf: stopLines(stop, of: without, cap: Self.withoutErrorCap, paths: paths, side: "without \(pathspecs)"))
            if let hint = unusedValueHint() {
                lines.append(hint)
            }
        }
        lines.append(contentsOf: listing(tests))
        if let note = oldTestNote(tests) {
            lines.append(note)
        }
        if let stop = stopWith {
            lines.append(contentsOf: stopLines(stop, of: with, cap: Self.withErrorCap, paths: paths, side: "with it"))
        }
        lines.append(setAsideLine())
        if !restored.record.leftInPlace.isEmpty {
            lines.append(leftInPlaceLine())
        }
        if let line = Self.stragglersLine(stragglers, pathspecs: pathspecs) {
            lines.append(line)
        }
        lines.append(contentsOf: restored.kept.map {
            "  ⚠ changed while it was set aside, so kept rather than overwritten: \($0)"
        })
        if watcherLost {
            lines.append(Self.watcherLostLine)
        }
        lines.append("")
        lines.append(contentsOf: runLines(without, named: "without \(pathspecs)"))
        lines.append(contentsOf: runLines(with, named: withName))
        lines.append("")
        lines.append(receipt(answerLines: lines.count + 1, paths: paths))
        let text = lines.joined(separator: "\n")
        return RunOutcome.Answer(text: text, lines: lines.count)
    }

    /// Whether every named test failed without the change and passed with it, both runs on one commit — the one answer that exits `0`.
    ///
    /// Judged over the tests left once those the change never touched are folded away, as the headline is: a test the change never wrote, passing both ways, is the expected case and proves nothing either way. Where every test folds, none the change wrote ran, and nothing is proven.
    var proven: Bool {
        let survivors = survivors(testLines())
        guard headNow == nil, stopWithout == nil, stopWith == nil, !survivors.isEmpty,
              !(without.report?.testOutcomes ?? RunTestOutcomes()).isEmpty
        else {
            return false
        }
        return survivors.allSatisfy { $0.standing == .pins }
    }
}

extension RunWithoutAnswer {
    /// How one test came out of one run.
    enum Outcome: Equatable {
        case passed
        case failed
        case skipped
        /// Started and never finished — the run ended while it was running.
        case unfinished
        /// Not reported at all.
        case absent
        /// Several tests print this one name, and they did not agree.
        case mixed(passed: Int, failed: Int)

        init(_ tally: RunTestOutcomes.Tally?, last: RunTestOutcomes.Ending?, retries: Bool) {
            guard let tally else {
                self = .absent
                return
            }
            // A retried test is one test, however many attempts it printed: the last is the one that counts.
            if retries, let last {
                self = switch last {
                case .passed: .passed
                case .failed: .failed
                case .skipped: .skipped
                }
                return
            }
            if tally.failed > 0, tally.passed > 0 {
                self = .mixed(passed: tally.passed, failed: tally.failed)
            } else if tally.failed > 0 {
                self = .failed
            } else if tally.passed > 0 {
                self = .passed
            } else if tally.skipped > 0 {
                self = .skipped
            } else {
                self = tally.started > 0 ? .unfinished : .absent
            }
        }
    }

    /// Where a test lands in the answer, in the order the answer lists them.
    enum Standing: Int, Comparable {
        case pinsNothing
        case failsBothWays
        case breaksWithIt
        case indistinct
        case undecided
        /// It passes with the change, and without it the tests did not compile: the change is needed for the test to build, which is weaker than the test failing an assertion without it — a test that merely names the new API stands here beside one that pins its behaviour.
        case needsIt
        case pins

        static func < (lhs: Standing, rhs: Standing) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var glyph: String {
            switch self {
            case .pins: "✔"
            case .pinsNothing, .failsBothWays, .breaksWithIt, .indistinct: "✘"
            case .undecided: "⚠"
            case .needsIt: "◇"
            }
        }
    }

    struct TestLine {
        let name: String
        let standing: Standing
        let sentence: String
        /// Passes with the change at the first try, and the run without it never built: the one thing its line says is that nothing ran there, so the listing counts it rather than naming it.
        ///
        /// A pass that took a retry keeps its line, since its retry note is the one thing a count would lose.
        var neverBuilt = false
    }

    /// One line of the listing: a test named on its own, or the tests the change never touched, counted into one.
    ///
    /// A test the change did not write passing both ways is the case a suite exists for, and a line apiece for them buries the exceptions the listing is ordered to show first.
    enum Listed {
        case test(TestLine)
        case untouched(Int)
        /// The tests that passed with the change after a run without it that did not build, counted into one line.
        case neverBuilt(Int)

        /// How many tests this line answers for — what the `+N more:` tail counts, so folding cannot make it lie.
        var tests: Int {
            switch self {
            case .test: 1
            case let .untouched(count), let .neverBuilt(count): count
            }
        }

        /// Where the one test this line names stands; `nil` for a count of folded tests, which names none.
        var standing: Standing? {
            switch self {
            case let .test(line): line.standing
            case .untouched, .neverBuilt: nil
            }
        }
    }

    /// Why a run reported no test at all, when it failed before reaching them.
    enum Stop: Equatable {
        /// Compiler errors in files that import a test framework: the tests themselves did not build.
        case testsDidNotCompile([RunDiagnostic.Identity])
        /// In an `xcodebuild` run without the change only: compiler errors in test files that each say a module could not be found, and nothing else wrong in a test file — counted neither way, since that run builds in derived data of its own, where a module another scheme builds is missing.
        case moduleNotFound(MissingModules)
        /// Compiler errors, none of them in a test file.
        case buildFailed
        /// No compiler error at all — a wrong scheme, a missing tool, a crash before the first test.
        case failedBeforeTests
    }

    /// The modules the run without the change could not find, the errors that say so, and what the set-aside says about why.
    struct MissingModules: Equatable {
        /// Each module once, sorted.
        let names: [String]
        /// The errors in test files that name them — the ones the answer quotes.
        let errors: [RunDiagnostic.Identity]
        /// Whether a path set aside is a build definition, or is named for one of the modules — a folder, or a built module's file — so the change may be what provides it.
        let changeMayProvide: Bool
    }

    func testLines() -> [TestLine] {
        let before = without.report?.testOutcomes ?? RunTestOutcomes()
        let after = with.report?.testOutcomes ?? RunTestOutcomes()
        let names = Set(before.names).union(after.names).sorted()
        let stop = stopWithout
        let withoutCompiled = stop.map {
            if case .testsDidNotCompile = $0 {
                false
            } else {
                true
            }
        } ?? true
        let buildBroke = stop == .buildFailed || stop == .failedBeforeTests
        return names.map { name in
            let outcomes = (
                Outcome(before[name], last: before.lastEndings[name], retries: retriesFailures),
                Outcome(after[name], last: after.lastEndings[name], retries: retriesFailures)
            )
            let (standing, sentence) = judge(outcomes.0, outcomes.1, name: name, compiledWithout: withoutCompiled)
            let note = retryNote(name, before: before, after: after)
            return TestLine(
                name: name,
                standing: standing,
                sentence: sentence + note,
                neverBuilt: buildBroke && note.isEmpty && outcomes.0 == .absent && outcomes.1 == .passed
            )
        }
        .sorted { ($0.standing, $0.name) < ($1.standing, $1.name) }
    }

    /// Says a retried test's earlier failures rather than letting its last attempt stand silently for all of them.
    private func retryNote(_ name: String, before: RunTestOutcomes, after: RunTestOutcomes) -> String {
        guard retriesFailures else {
            return ""
        }
        var notes: [String] = []
        for (outcomes, side) in [(before, "without \(pathspecs)"), (after, "with it")] {
            guard let tally = outcomes[name], tally.failed > 0, outcomes.lastEndings[name] == .passed else {
                continue
            }
            notes.append("\(side) it passed only on a retry, after \(tally.failed == 1 ? "1 failure" : "\(tally.failed) failures")")
        }
        return notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
    }

    private func judge(_ before: Outcome, _ after: Outcome, name: String, compiledWithout: Bool) -> (Standing, String) {
        let withIt = failureDetail(of: name).map { " — with it: \($0)" } ?? ""
        guard compiledWithout else {
            return switch after {
            case .passed: (.needsIt, "passes with it; without \(pathspecs) it did not compile — needed, not pinned")
            case .failed: (.failsBothWays, "fails with it\(withIt)")
            default: (.undecided, "\(describe(after)) with it")
            }
        }
        return switch (before, after) {
        case (.failed, .passed):
            (.pins, "fails without \(pathspecs), passes with it")
        case (.passed, .passed):
            (.pinsNothing, "passes without \(pathspecs) too, so it pins nothing")
        case (.failed, .failed):
            (.failsBothWays, "fails both ways\(withIt)")
        case (.passed, .failed):
            (.breaksWithIt, "passes without \(pathspecs) and fails with it\(withIt)")
        case let (.mixed(passed, failed), _):
            (.indistinct, "\(passed + failed) tests print this name, and without \(pathspecs) \(passed) passed and \(failed) failed — the log cannot tell them apart")
        case let (_, .mixed(passed, failed)):
            (.indistinct, "\(passed + failed) tests print this name, and with it \(passed) passed and \(failed) failed — the log cannot tell them apart")
        case (.absent, _):
            (.undecided, "did not run without \(pathspecs); \(describe(after)) with it")
        case (_, .absent):
            (.undecided, "\(describe(before)) without \(pathspecs), and did not run with it")
        default:
            (.undecided, "\(describe(before)) without \(pathspecs), \(describe(after)) with it")
        }
    }

    private func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .passed: "passed"
        case .failed: "failed"
        case .skipped: "skipped"
        case .unfinished: "started and never finished"
        case .absent: "did not run"
        case let .mixed(passed, failed): "\(passed) passed and \(failed) failed under one name"
        }
    }

    /// The first failure the run with the change recorded against `name`, as `location: message`, shortened to one line.
    private func failureDetail(of name: String) -> String? {
        guard let failure = with.report?.testFailures.first(where: { $0.name == name }) else {
            return nil
        }
        let message = failure.message.count > 120 ? String(failure.message.prefix(119)) + "…" : failure.message
        return failure.location.map { "\($0): \(message)" } ?? message
    }

    /// Why the run without the change reported no test — the one run whose missing modules are read apart, and only under `xcodebuild`: it alone builds in derived data of its own, where a module only ever built elsewhere (by another scheme, into the caller's DerivedData) is missing.
    ///
    /// Never under SwiftPM, which builds the package's whole graph into the scratch path it is handed: nothing a test there can import is built anywhere else, so a module `swift test` cannot find is one the package, as the run found it, does not provide — a dependency the change adds in `Package.swift`, say — and reads as any other error in a test file does: evidence the tests need the change.
    var stopWithout: Stop? {
        stop(of: without, readingMissingModules: without.kind == .xcodebuild)
    }

    /// Why the run with the change reported no test.
    ///
    /// It builds where the caller's builds do, so a module it cannot find is the tests not compiling, like any other error in a test file — with the change the first suspect.
    var stopWith: Stop? {
        stop(of: with, readingMissingModules: false)
    }

    /// Why a run reported no test, when it failed without reaching one; `nil` for a run that reached its tests, or did not fail.
    ///
    /// A run that printed tests in the shape `xcodebuild` uses for parallel clones reached its tests, whatever else it printed: its assertion failures are not a build that broke, nor tests that did not compile.
    private func stop(of outcome: RunOutcome, readingMissingModules: Bool) -> Stop? {
        guard outcome.exitCode != 0, outcome.report?.testOutcomes.isEmpty ?? true, (outcome.report?.testOutcomes.parallelLines ?? 0) == 0 else {
            return nil
        }
        let located = (outcome.report?.errors ?? []).filter { $0.path != nil && $0.line != nil }
        let inTests = located.filter { $0.sourcePath.map(isTestSource) ?? false }
        if readingMissingModules, let missing = missingModules(among: inTests) {
            return .moduleNotFound(missing)
        }
        if !inTests.isEmpty {
            return .testsDidNotCompile(inTests.map(\.identity))
        }
        // A compiler crash is a build that failed, though the one line it prints at a file and line is claimed by the crash reader.
        return located.isEmpty && outcome.report?.compilerCrash == nil ? .failedBeforeTests : .buildFailed
    }

    /// The modules named by `inTests`, the compiler errors in test files, when every one of them says a module could not be found; `nil` when none does, or when any other error in a test file says the tests themselves did not compile — that one is evidence, and the module errors are quoted beside it.
    private func missingModules(among inTests: [RunDiagnostic]) -> MissingModules? {
        let names = inTests.compactMap { Self.missingModule(in: $0.message) }
        guard !names.isEmpty, names.count == inTests.count else {
            return nil
        }
        let unique = Array(Set(names)).sorted()
        return MissingModules(names: unique, errors: inTests.map(\.identity), changeMayProvide: setAsideMayProvide(unique))
    }

    /// The module a compiler error says it could not find, in each wording a toolchain uses for it: `no such module 'X'`; the dependency scanner's `Unable to resolve module dependency: 'X'`, captured from Xcode 27 and, in lower case, from `swift test` under Swift 6.4; and `Unable to find module dependency: 'X'`, the wording reported for Xcode 16.
    ///
    /// Never a partial import or a downstream `cannot find type`, which read the same as a change the test itself needs.
    private static func missingModule(in message: String) -> String? {
        guard let match = message.firstMatch(of: #/(?:no such module|[Uu]nable to (?:resolve|find) module dependency:) '([^']+)'/#) else {
            return nil
        }
        return String(match.1)
    }

    /// Whether a path set aside could be what provides `modules`: a build definition, which says what modules there are and how each is built, or a path named for one of them.
    ///
    /// Only the paths are read, never what they hold — which is all the answer's wording claims.
    private func setAsideMayProvide(_ modules: [String]) -> Bool {
        restored.record.entries.contains { entry in
            let components = entry.path.split(separator: "/").map(String.init)
            return Self.isBuildDefinition(components) || Self.isNamed(for: modules, components)
        }
    }

    /// Whether the path `components` spell is named for one of `modules`: in a folder named for it — `Sidecar/`, or `Sidecar.xcframework/`, `Sidecar.framework/`, `Sidecar.swiftmodule/` — or itself a built module's file, `Sidecar.swiftmodule` or `Sidecar.swiftinterface`.
    ///
    /// Each name is compared by what comes before its first extension, since a module's own name has none.
    private static func isNamed(for modules: [String], _ components: [String]) -> Bool {
        guard let name = components.last else {
            return false
        }
        let stem = { (component: String) in String(component.prefix { $0 != "." }) }
        if components.dropLast().contains(where: { modules.contains(stem($0)) }) {
            return true
        }
        let builtModule = ["swiftmodule", "swiftinterface", "framework", "xcframework"]
        return name.split(separator: ".").last.map { builtModule.contains(String($0)) } == true && modules.contains(stem(name))
    }

    /// Whether the path `components` spell defines what a build builds, or which modules it can find: a package manifest or `Package.resolved`, anything in an Xcode project or workspace, an `.xcconfig`, a Clang module map, or an XcodeGen or Tuist project description.
    private static func isBuildDefinition(_ components: [String]) -> Bool {
        guard let name = components.last else {
            return false
        }
        if ["Package.swift", "Package.resolved", "project.yml", "Project.swift"].contains(name) || name.hasSuffix(".xcconfig") || name.hasSuffix(".modulemap") {
            return true
        }
        if name.hasPrefix("Package@swift-"), name.hasSuffix(".swift") {
            return true
        }
        return components.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// What the answer can say about why the run without the change could not find `missing`, worded as what was checked — the paths set aside, and nothing more.
    private static func whyMissing(_ missing: MissingModules) -> String {
        let one = missing.names.count == 1
        if missing.changeMayProvide {
            return "the change may provide \(one ? "it" : "them"), or \(one ? "it is" : "they are") only built outside this run's build directory, so \(one ? "it is" : "they are") counted neither way"
        }
        return "none of the paths set aside is a manifest, lockfile, project, settings or module-map file this recognises, or a folder or built-module file named for \(one ? "it" : "any of them"), so \(one ? "it is" : "they are") read as missing from this run's own build directory, not as evidence"
    }

    /// `modules`, named the way a sentence reads them: one module by name, several as a list.
    private static func moduleList(_ modules: [String]) -> String {
        let quoted = modules.map { "'\($0)'" }
        return modules.count == 1 ? "module \(quoted[0])" : "modules \(quoted.joined(separator: ", "))"
    }

    /// Whether `path` is a file that imports a test framework — the evidence behind saying the *tests* did not compile, rather than something else in the build.
    private func isTestSource(_ path: String) -> Bool {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path)
        return Self.head(ofFileAt: url).map(Self.importsATestFramework) ?? false
    }

    /// Whether `text` imports a test framework, however the import is spelled: behind attributes (`@testable`, `@preconcurrency`, `@_spi(…)`), an access level, or naming one declaration out of the module (`import struct Testing.Test`).
    ///
    /// The module name ends at `(?!\w)` rather than `\b`: a Swift regex's word boundary is Unicode's, which reads `Testing.Test` as one word.
    static func importsATestFramework(_ text: String) -> Bool {
        text.contains(#/(?:^|\n)[ \t]*(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(?:XCTest|Testing)(?!\w)/#)
    }

    /// The start of the file at `url` as text — as much of it as any question here asks about; `nil` when there is no such file, or it is not UTF-8.
    private static func head(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 18) else {
            return nil
        }
        return String(bytes: head, encoding: .utf8)
    }

    private func headline(_ tests: [TestLine]) -> String {
        let before = without.report?.testOutcomes ?? RunTestOutcomes()
        let after = with.report?.testOutcomes ?? RunTestOutcomes()
        if let headNow {
            return "⚠ HEAD moved from \(restored.record.head.prefix(10)) to \(headNow.prefix(10)) while the tests ran, so the two runs did not start from one commit — nothing was proven; the changes are back on top of it"
        }
        switch stopWith {
        case .testsDidNotCompile, .moduleNotFound:
            return "✘ the tests do not compile with \(pathspecs) — nothing was proven"
        case .buildFailed, .failedBeforeTests:
            let both = stopWithout != nil ? ", both without \(pathspecs) and with it" : " with \(pathspecs) in place"
            return "✘ the command failed before running tests\(both) — nothing was proven"
        case nil:
            break
        }
        switch stopWithout {
        case .testsDidNotCompile:
            let passing = tests.count { $0.standing == .needsIt }
            return "◇ the tests did not compile without \(pathspecs) — evidence they need it, not a failing assertion; \(passing) of \(tests.count) \(passing == 1 ? "passes" : "pass") with it"
        case let .moduleNotFound(missing):
            return "⚠ \(Self.moduleList(missing.names)) could not be found without \(pathspecs) — \(Self.whyMissing(missing)); nothing was proven"
        case .buildFailed, .failedBeforeTests:
            return "✘ the command failed before running tests without \(pathspecs) — nothing was proven"
        case nil:
            break
        }
        let parallel = before.parallelLines + after.parallelLines > 0
        if before.isEmpty, after.isEmpty {
            guard parallel else {
                return "⚠ neither run reported a test — check that the filter names one; nothing was proven"
            }
            return "⚠ neither run reported a test in a form this reads — xcodebuild ran them in parallel, each from a clone of the test runner; run it again with `-parallel-testing-enabled NO` — nothing was proven"
        }
        if before.isEmpty {
            return parallel
                ? "⚠ the run without \(pathspecs) reported no test in a form this reads — xcodebuild ran them in parallel; run it again with `-parallel-testing-enabled NO` — nothing was proven"
                : "⚠ the run without \(pathspecs) reported no test — see its raw log; nothing was proven"
        }
        // Counted over the tests the listing names, as `proven` is: a folded test draws no line of its own,
        // so it draws neither the headline's glyph nor a place in its count.
        let survivors = survivors(tests)
        guard !survivors.isEmpty else {
            let folded = tests.count == 1 ? "1 untouched passes" : "\(tests.count) untouched pass"
            let note = ChangedTests.noBranchRangeNote(since: restored.record.since, in: workingDirectory).map { " — \($0)" } ?? ""
            return "⚠ no test the change wrote ran under this filter — \(folded) both ways; nothing was proven\(note)"
        }
        let pinning = survivors.count { $0.standing == .pins }
        let glyph = if pinning == survivors.count {
            "✔"
        } else if survivors.contains(where: { $0.standing.glyph == "✘" }) {
            "✘"
        } else {
            "⚠"
        }
        let verbs = pinning == 1 ? "fails without \(pathspecs) and passes with it" : "fail without \(pathspecs) and pass with it"
        return "\(glyph) \(pinning) of \(survivors.count) \(verbs)"
    }

    /// The tests left once those the change never touched are folded away: the ones the listing names, and the ones the headline and ``proven`` count.
    private func survivors(_ tests: [TestLine]) -> [TestLine] {
        tests.filter { !isUntouched($0) }
    }

    /// Whether `test` passes both ways and is one the change never wrote — the expected case, and so not a finding.
    ///
    /// Matched on the bare identifier, both sides reduced by ``identifier(of:)``: a run prints `Suite.name()` or `name()`, and a declaration is written `name()`. Two suites declaring one name are the same test here, which is the convention ``declares(test:in:)`` already follows.
    private func isUntouched(_ test: TestLine) -> Bool {
        guard test.standing == .pinsNothing, let changedTests, Self.namesADeclaration(test.name) else {
            return false
        }
        let identifier = Self.identifier(of: test.name)
        // A name that reduces to nothing matches nothing either way, so it keeps a line of its own.
        return !identifier.isEmpty && !changedTests.contains(identifier)
    }

    /// Whether a name a run printed is one a declaration could be matched against at all.
    ///
    /// A Swift Testing test declared `@Test("the widget keeps its heading")` prints that display name, quoted, and ``RunTestOutcomes`` keeps it whole. There is no declaration identifier inside it: ``identifier(of:)`` reduces it to the last word of the prose, which no change's declarations can ever contain. Such a name is **undetermined** rather than untouched, and folding it would be the one mistake this feature must not make — deleting the line that names a test the change wrote, and asserting in its place that the change does not touch it.
    private static func namesADeclaration(_ name: String) -> Bool {
        !name.contains("\"")
    }

    /// The listing's lines: one per test, with the tests the change never touched folded into one where those lines sorted.
    ///
    /// Folded before the cap rather than after, so what keeps a long run inside it is the fold, not the cap hiding the tests that matter.
    private func listed(_ tests: [TestLine]) -> [Listed] {
        var lines: [Listed] = []
        var folded = 0
        var placedAt: Int?
        var unbuilt = 0
        var unbuiltAt: Int?
        for test in tests {
            if test.neverBuilt {
                if unbuiltAt == nil {
                    unbuiltAt = lines.count
                    lines.append(.neverBuilt(0))
                }
                unbuilt += 1
                continue
            }
            guard isUntouched(test) else {
                lines.append(.test(test))
                continue
            }
            if placedAt == nil {
                placedAt = lines.count
                lines.append(.untouched(0))
            }
            folded += 1
        }
        if let placedAt {
            lines[placedAt] = .untouched(folded)
        }
        if let unbuiltAt {
            lines[unbuiltAt] = .neverBuilt(unbuilt)
        }
        return lines
    }

    private func line(of listed: Listed) -> String {
        switch listed {
        case let .test(test):
            "  \(test.standing.glyph) \(test.name) — \(test.sentence)"
        case let .untouched(count):
            count == 1
                ? "  1 test the change does not touch passes without \(pathspecs) too — expected, so it is not listed"
                : "  \(count) tests the change does not touch pass without \(pathspecs) too — expected, so they are not listed"
        case let .neverBuilt(count):
            "  \(count) \(count == 1 ? "test passes" : "tests pass") with it and did not run without \(pathspecs), which did not build"
        }
    }

    private func listing(_ tests: [TestLine]) -> [String] {
        let listed = listed(tests)
        var lines = listed.prefix(Self.testLineCap).map(line(of:))
        let rest = listed.dropFirst(Self.testLineCap)
        guard !rest.isEmpty else {
            return lines
        }
        let remaining = rest.reduce(0) { $0 + $1.tests }
        let pinning = rest.count { $0.standing == .pins }
        let needing = rest.count { $0.standing == .needsIt }
        // Counted apart, because a test that only failed to compile without the change did not fail an
        // assertion either way, and folding it into "do not" reads as a test that went the wrong way.
        let needed = needing > 0 ? ["\(needing) pass with it and did not compile without it"] : []
        let others = remaining - pinning - needing
        let parts = ["\(pinning) fail without \(pathspecs) and pass with it"] + needed + ["\(others) do not"]
        lines.append("  +\(remaining) more: \(parts.joined(separator: ", ")) — see the raw logs")
        return lines
    }

    /// The note a verdict of "pins nothing" owes when the test that drew it went into the set-aside beside the sources: the run compared the committed test, not the edited one.
    ///
    /// A committed test passes against the committed sources by construction, so that verdict is true of a test the caller never wrote, and reads as their fix being unpinned — the kind of line that talks somebody out of a correct change. It is owed only where the two facts meet: a test file whose text names the very test that pinned nothing. A test file set aside beside a test that ran from the tree all along drew an honest verdict, and a note over that one talks the caller out of a correct negative instead.
    ///
    /// What it names is a technique rather than a flag, because there is no flag: a test left in the tree has to compile against the old sources to run against them at all, which means asserting a consequence rather than naming something only the change declares — and where the change is the declaration, there is no such assertion to write.
    private func oldTestNote(_ tests: [TestLine]) -> String? {
        // A test folded away as untouched draws no note: the run compared a committed test the change never wrote, which is the expected case rather than a verdict anybody could be talked out of.
        let unpinned = tests.filter { $0.standing == .pinsNothing && !isUntouched($0) }.map { Self.identifier(of: $0.name) }.filter { !$0.isEmpty }
        guard !unpinned.isEmpty else {
            return nil
        }
        let inTests = restored.record.entries.map(\.path).filter { path in
            // The whole file, not `head`: a test declared past the head window must still draw this note,
            // or a change that only edited a late test reads as pinning nothing when it pinned the old one.
            guard let text = try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8) else {
                return false
            }
            // No import gate: `declares` already asks for the test's own declaration, and a gate that missed an
            // unusual import would drop the note and leave the committed test's verdict read as the edited one's.
            return unpinned.contains(where: { Self.declares(test: $0, in: text) })
        }
        guard !inTests.isEmpty else {
            return nil
        }
        let named = inTests.prefix(3).joined(separator: ", ") + (inTests.count > 3 ? " and \(inTests.count - 3) more" : "")
        let ran = inTests.count == 1
            ? "was also set aside, so this ran the committed test, not your edited one"
            : "were also set aside, so this ran the committed tests, not your edited ones"
        return "  note: \(named) \(ran). To gate an edited test against old sources, leave the test file out of --without and write its assertions to compile against them. Where the change declares what the test has to name — a new case, method or type — no assertion compiles against the old sources, and the most this can show is that the tests needed the change, not a failing assertion."
    }

    /// The bare test name a run printed, whatever form it printed it in: `shoutingWorks()`, `WidgetTests.testNaming`, `-[WidgetTests testNaming]`.
    static func identifier(of name: String) -> String {
        let bare = name.hasSuffix("()") ? String(name.dropLast(2)) : name
        let tail = bare.split(whereSeparator: { $0 == "." || $0 == " " || $0 == "/" }).last ?? ""
        return String(tail.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Whether `text` declares a test function named `name`, rather than merely mentioning it — a comment, a doc line, or as part of a longer identifier (`run` inside `running`) all pass a bare substring match but declare nothing.
    ///
    /// Matched as `func ` immediately followed by `name` and `(`, which is what a function declaration of that name looks like regardless of what precedes it on the line (attributes, indentation, `private`, `static`). Cheap and syntactic on purpose: this is an attribution note, not a claim the index backs.
    private static func declares(test name: String, in text: String) -> Bool {
        text.contains("func \(name)(")
    }

    /// What a run that stopped before its tests printed: the compiler errors in test files where that is why, and otherwise the first error it gave.
    private func stopLines(_ stop: Stop, of outcome: RunOutcome, cap: Int, paths: RunAnswerPaths, side: String) -> [String] {
        let errors = outcome.report?.errors ?? []
        switch stop {
        case let .testsDidNotCompile(identities):
            let inTests = errors.filter { identities.contains($0.identity) }
            let heading = side == "with it" ? ["  with it, the tests did not compile:"] : []
            return heading + quoted(inTests, cap: cap, paths: paths)
        case let .moduleNotFound(missing):
            // Only the errors in test files that name a module; every other error is counted, never dropped.
            let named = errors.filter { missing.errors.contains($0.identity) }
            let others = errors.count - named.count
            let rest = others > 0 ? ["    +\(others) other error\(others == 1 ? "" : "s") — see the raw log"] : []
            return ["  \(side), \(Self.moduleList(missing.names)) could not be found:"] + quoted(named, cap: cap, paths: paths) + rest
        case .buildFailed, .failedBeforeTests:
            guard let first = errors.first else {
                if let crash = outcome.report?.compilerCrash {
                    return ["  \(side), the build failed before any test ran: the compiler crashed"] + crash.lines().map { "  \($0)" }
                }
                return ["  \(side), the command exited \(outcome.exitCode) before any test ran, and printed no error — see its raw log"]
            }
            let what = stop == .buildFailed ? "the build failed" : "the command failed"
            let more = errors.count > 1 ? "; +\(errors.count - 1) more error\(errors.count == 2 ? "" : "s") in the raw log" : ""
            return ["  \(side), \(what) before any test ran\(more):"] + quoted([first], cap: 1, paths: paths)
        }
    }

    private func quoted(_ errors: [RunDiagnostic], cap: Int, paths: RunAnswerPaths) -> [String] {
        var lines = errors.prefix(cap).map { error in
            "    " + (paths.shown(error).described.split(separator: "\n").first.map(String.init) ?? error.message)
        }
        if errors.count > cap {
            lines.append("    +\(errors.count - cap) more errors — see the raw log")
        }
        return lines
    }

    /// What the answer says about the paths the set-aside took out of the tree outright, when the tests then did not compile without the change: why that is all the run without it could show, and what it leaves unanswered.
    ///
    /// Said only where the tests did not compile, which is the one outcome a removed file explains: a new file the tests never name leaves them compiling, and the answer is the ordinary one.
    ///
    /// It names what the remaining step needs rather than a command to run, because there is none: every way to make the file's own behaviour wrong needs the file committed first, and a run that then set that edit aside would be proving the edit, not the fix.
    private func newFilesLine() -> String? {
        guard case .testsDidNotCompile = stopWithout, let clause = Self.newFilesClause(restored.record) else {
            return nil
        }
        // Under `--since` the file is already committed — that is the whole reason it is missing only from
        // the older revision — so the advice a HEAD run gives, to commit it, is one the reader has already done.
        let needs = restored.record.since == nil
            ? "that needs the file committed and what it does changed"
            : "that needs what it does changed, in a commit of its own"
        return "  \(clause): a test that names what it declared could not build, and none failed an assertion without \(pathspecs). Whether a test pins what the file does, rather than merely naming it, is not shown — \(needs)."
    }

    /// What the answer says when a set-aside line left the build with nothing but unused-value errors for names that line read: the line was the only reader of a binding, so the hand form `_ = name` keeps the read and removes the store.
    ///
    /// `nil` for any other stop, and for a build that failed for any reason besides: one error that is not an unused value is evidence, and is quoted, not explained away.
    private func unusedValueHint() -> String? {
        guard let line = restored.record.line, let errors = without.report?.errors, !errors.isEmpty else {
            return nil
        }
        let read = Self.identifiers(in: line.text)
        var names: [String] = []
        for error in errors {
            guard error.path.map({ $0 == line.path || $0.hasSuffix("/" + line.path) }) ?? false,
                  error.message.contains("never used"),
                  let name = Self.quotedName(in: error.message),
                  read.contains(name)
            else {
                return nil
            }
            if !names.contains(name) {
                names.append(name)
            }
        }
        let forms = names.prefix(3).map { "`_ = \($0)`" }.joined(separator: ", ")
        return "  the only errors are unused values that \(line.path):\(line.number) read (\(names.prefix(3).joined(separator: ", "))): set the line aside by hand as \(forms) in its place so the name keeps a reader, or run `--without` on the fix's file"
    }

    /// The first name a compiler message puts between single quotes.
    private static func quotedName(in message: String) -> String? {
        let parts = message.split(separator: "'", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[1]) : nil
    }

    /// The words of `text` that could be an identifier.
    private static func identifiers(in text: String) -> Set<String> {
        Set(text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
    }

    /// What the run with the change is called in the answer: `with it`, or, for a line commented out, the line named as back.
    private var withName: String {
        restored.record.line.map { "with \($0.path):\($0.number) back" } ?? "with it"
    }

    private func setAsideLine() -> String {
        Self.setAsideLine(restored.record, pathspecs: pathspecs)
    }

    /// The receipt for what a set-aside took out of the tree and put back — shared by the ordinary answer and by one that stopped before the run with the change, so both quote the one rendering rather than two copies of the same words.
    public static func setAsideLine(_ record: SetAsideRecord, pathspecs: String) -> String {
        if let line = record.line {
            let how = line.replacement.map { "set aside as `\($0)`" } ?? "commented out"
            return "  set aside: \(line.path):\(line.number) — \"\(line.text.trimmingCharacters(in: .whitespacesAndNewlines))\" (\(how) for the run without the change)"
        }
        let split = record.split
        let paths = record.entries.count == 1 ? "1 path" : "\(record.entries.count) paths"
        var parts: [String] = []
        if split.staged > 0 {
            parts.append("\(split.staged) with staged changes")
        }
        if split.unstaged > 0 {
            parts.append("\(split.unstaged) with unstaged changes")
        }
        if split.untracked > 0 {
            parts.append("\(split.untracked) untracked")
        }
        // `Entry.status` is empty for a committed change, so a `--since` run's parts are always empty here —
        // said instead as what it was committed since, rather than as the empty parenthesis that leaves.
        let detail = parts.isEmpty
            ? record.since.map { " (committed since \(String($0.prefix(10))))" } ?? ""
            : " (\(parts.joined(separator: ", ")))"
        return "  set aside and put back: \(paths) under \(pathspecs)\(detail), checked by content hash"
    }

    private func leftInPlaceLine() -> String {
        Self.leftInPlaceLine(restored.record)
    }

    /// The receipt for what a set-aside left in place rather than moving — shared the same way as ``setAsideLine(_:pathspecs:)``.
    public static func leftInPlaceLine(_ record: SetAsideRecord) -> String {
        let own = record.leftInPlace
        let named = own.prefix(3).joined(separator: ", ") + (own.count > 3 ? " and \(own.count - 3) more" : "")
        return "  left in place: \(named) — changed, but in this tool's own \(SiftPaths.directoryName)/ directory, which a set-aside never moves"
    }

    /// The line an answer carries for the processes the run without the change left running, ended before the changes went back — `nil` when none did.
    public static func stragglersLine(_ stragglers: Int, pathspecs: String) -> String? {
        guard stragglers > 0 else {
            return nil
        }
        return "  stopped \(stragglers == 1 ? "1 process" : "\(stragglers) processes") the run without \(pathspecs) left running, before putting the changes back"
    }

    /// Where one run's raw output was written, as the receipt states it — `outcome`'s own line from ``receipt(answerLines:paths:)``, shared so a run that never reaches the receipt still quotes the one rendering.
    public static func logLine(_ outcome: RunOutcome, named name: String, paths: RunAnswerPaths) -> String {
        outcome.log.map { "\(paths.shown($0.url.path)) (\(name))" } ?? "no raw log could be written (\(name))"
    }

    /// One run's own verdict and closing counts, exactly as `run` would headline it.
    private func runLines(_ outcome: RunOutcome, named name: String) -> [String] {
        guard let report = outcome.report else {
            return ["\(name) — exit \(outcome.exitCode)"]
        }
        let renderer = RunReportRenderer(kind: outcome.kind, workingDirectory: workingDirectory, selector: selector)
        return ["\(name) — \(renderer.headline(report, exitCode: outcome.exitCode))"]
            + renderer.summaries(of: report).map { "  \($0)" }
    }

    private func receipt(answerLines: Int, paths: RunAnswerPaths) -> String {
        let total = (without.report?.totalLines ?? 0) + (with.report?.totalLines ?? 0)
        let arithmetic = "sift run: \(total) lines in, \(answerLines) out"
        let logs = [(without, "without \(pathspecs)"), (with, withName)].map { Self.logLine($0, named: $1, paths: paths) }
        let built = buildDirectory.map { directory in
            guard !buildDirectoryRemoved else {
                let size = buildDirectorySize.map { "\(Self.described(bytes: $0)), " } ?? ""
                return "; built without the change in a scratch build (\(size)removed)"
            }
            // Named from where the run started, which can be below the repository root, and quoted, since a
            // repository's path can hold what a shell would split.
            let shown = paths.shown(directory)
            let size = buildDirectorySize.map { " (\(Self.described(bytes: $0)))" } ?? ""
            return "; the run without the change built in \(shown)\(size) — remove it any time with `rm -rf \(ShellWord.quoted(shown))`"
        } ?? ""
        return arithmetic + " — raw output at " + logs.joined(separator: " and ") + built
    }

    private static func described(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
