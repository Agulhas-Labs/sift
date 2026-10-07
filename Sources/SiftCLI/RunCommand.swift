//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift run -- <command>` — the wrapped command's failures without its build noise.
struct RunCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "run",
            abstract: "Run a Swift toolchain command and print only what failed.",
            // Written out because the generated line draws every array option as repeatable (`<file:line> ...`), and `--without-line` is one value, refused when given twice.
            usage: "sift run [<command> ...] [--without <without> ...] [--without-line <file:line>] [--since <since>] [--restore] [--proved] [--coverage] [--from <from>]",
            discussion: """
            Wraps `swift build`, `swift test` and `xcodebuild`, printing their errors, test failures, \
            deduplicated warnings and own summary line instead of the thousands of progress lines a \
            verify loop otherwise costs. The wrapped command's exit code is passed through exactly, with \
            two exceptions: a run that names its tests (`swift test --filter …`, `xcodebuild \
            -only-testing:…`), exits 0 and executed none of them answers ✘ and exits 4 — never 1 or 65, \
            which a gate would read as a test that failed — as does a run of several --filters where one \
            matched no test, which its totals line names, and the same run, when its build failed before \
            any test process started, answers ✘ … did not build — no test ran and exits 5. An unfiltered \
            `swift test` of a package whose manifest declares test targets that exits 0 having executed no \
            test answers ✘ … nothing ran: no test executed and exits 4 as well. A run that names \
            no tests keeps the wrapped command's exit when its build fails. The complete raw output is kept \
            in its own file under .sift/runs/, which the tail of \
            every answer names. Anything else runs untouched. stdout and stderr are merged into one \
            stream, as `2>&1` does.

            An unfiltered, serial `swift test` of the package at the repository's root is also checked \
            against the tests the index declares, and says so under totals: in one line — `inventory: N \
            declared, N reported` — or names the tests that never reported or reported more than once. \
            It is a note, never a verdict: the exit code stays the wrapped command's. A filtered, skipped \
            or --parallel run, a nested package's run and an xcodebuild run print nothing; a run in scope \
            that could not be checked (no index yet, it could not be read, every declared test was lifted \
            out of the counts, or more than 20 s to freshen and reconcile) prints one \
            `inventory: not checked — …` line.

            A swift test that executes tests is also asked for Swift Testing's event stream, in a file \
            under .sift/ removed once read. Where SwiftPM's relay of the console lost result lines, the \
            endings and failing tests it lost are read from the stream, and one line under totals: says \
            so — `event stream: N Swift Testing endings, the console relayed M — …`. Where the two agree, \
            where the run repeated its tests, or where no stream could be had, the answer is the console's alone.

            With --without <pathspec>, the named tests (`swift test --filter …` or \
            `xcodebuild test -only-testing:…`) run twice: first with every uncommitted change under the \
            pathspec set aside, then with the changes back. With --since <rev> beside it, what is set \
            aside is instead what the commits since that revision changed under the pathspec — the fix \
            is already committed — and a working tree with anything uncommitted under the pathspec is \
            refused, since the two are never mixed in one run. The answer says, test by test, whether each \
            fails without the change and passes with it. The changes are put back on every exit path — \
            a separate watcher process restores them if this one is killed — and checked by content hash; \
            while they are out of the tree, every `sift run` refuses, and `sift run --restore` puts back \
            a set-aside whose run is gone. The run without the change builds in a directory of its own \
            under .sift/without-build/, never in yours, so nothing compiled without the change is left \
            for your next build to reuse. A test the change did not write that passes both ways is \
            counted rather than listed; which tests it wrote is read from the branch's merge-base with \
            the default branch (or from --since), commits and uncommitted work together, so a test \
            committed beside an uncommitted fix still counts as written. With --without-line <file>:<line> \
            instead, what is set aside is one line of a Swift file, commented out in its own place (`// ` \
            after its indentation) — the proof for a fix that is a new file or new API, which set aside whole \
            can only fail to build. The file has to compile with the line commented out, so name a line \
            nothing after it depends on — a one-line `guard !… else { return }` that binds no name, a call. \
            Nor a guard that is the last reader of a local above it: the local is left unused, which a \
            warnings-as-errors package refuses, so route it through a helper whose parameters carry the \
            inputs. A `guard let` or `let` whose name a later line uses does not compile commented out; a `guard … \
            else {` that opens a block does not either, and neither does the `return` or \
            `throw` inside one, since a guard body must not fall through: such a fix needs --without, or a \
            set-aside by hand. A line that assigns one bare name (`settings = updated`) is set aside as \
            `_ = updated` instead, so the store goes and the name keeps a reader, and the answer says which form \
            it used; when the build still fails on nothing but unused values the line read, the answer \
            names that hand form. The watcher, the restore, the content-hash check and the exit codes are \
            the same, and a blank line, a line already a comment, or a file that is not Swift is refused \
            before anything moves. It exits 0 only when every \
            written test the filter ran failed without the change and passed with it; 1 when the runs proved nothing; 2 when it refused or stopped \
            before any test ran, with nothing out of the tree; 3 when changes are NOT back in the \
            tree; and 64 when the line itself is a usage error, said before anything moves: a command that \
            cannot prove anything run twice (tests not named, --skip-build, --parallel), a --since \
            revision git cannot resolve or HEAD does not descend from, a command that builds another \
            checkout, or flags that do not go together.
            """
        )
    }

    @Argument(parsing: .captureForPassthrough, help: "The command to run, and its arguments.")
    var command: [String] = []

    @Option(name: .customLong("without"), help: "Set aside the uncommitted changes under this pathspec, run the named tests, put the changes back and run them again. Repeatable.")
    var without: [String] = []

    @Option(name: .customLong("without-line"), help: ArgumentHelp("Comment out this one line of a Swift file, run the named tests, put the line back and run them again — for a fix that cannot build without its own change. The file has to compile with the line commented out: a one-line `guard !… else { return }` that binds no name does, unless it is the last reader of a local above it (route it through a helper whose parameters carry the inputs); a `guard … else {` that opens a block does not. Given once only: a run sets aside one line.", valueName: "file:line"))
    var withoutLine: [String] = []

    @Option(name: .customLong("since"), help: "Set aside what the commits since this revision changed under --without, rather than what is uncommitted: the fix is already committed. Refused when anything under the pathspec is uncommitted.")
    var since: String?

    @Flag(name: .customLong("restore"), help: "Put back the changes a `sift run --without` set aside and never restored, and check them by content hash.")
    var restore = false

    @Flag(name: .customLong("proved"), help: "Answer whether this command has already passed on this tree's exact content, and run nothing. Exit 0 when it has, 1 when no such run is on record or a later run on the same content failed (running the command would fix that), 2 when the question could not even be put — the ledger is switched off, or there is no repository, tree key or toolchain to name (running the command again cannot fix that).")
    var proved = false

    /// The watcher a `--without` run starts to restore the tree if it is killed; never typed by a person.
    @Option(name: .customLong("guard-set-aside"), help: .private)
    var guardSetAside: String?

    @Flag(name: .customLong("coverage"), help: "Run `swift test` or `xcodebuild test` with coverage on, then say which lines of each changed declaration the tests ran and which they did not.")
    var coverage = false

    @Option(name: .customLong("from"), help: "With --coverage: the revision the change is measured from (default HEAD); the after side is always the working tree.")
    var from: String?

    /// Where a run files itself — injected so a test can watch it happen.
    ///
    /// Defaulted to the shared per-user log, which is what every real invocation writes to. A seam is the only way this wiring can be pinned in process: the standard path follows the process's `HOME`, which a test cannot move without moving it for every suite running beside it, and without it nothing asserted that a wrapped run records its kind, its exit code, the lines it suppressed, or the repository it discovered.
    var log: RunUsageLog = .standard(note: { StandardStreams.emitError($0) })

    /// Where everything this run writes for itself lands — its transcript, its proof, the durations it seeds — injected so a fixture can watch those writes happen without any of them reaching this checkout.
    ///
    /// It is also the repository whose set-aside a plain run refuses to start on, so a fixture is refused by a set-aside of its own and never by one a real `sift run --without` has out in the checkout the test process runs in.
    ///
    /// Defaulted to `nil`, which means the root the run discovers for each of them, exactly as every real invocation does: the ledger and the durations store under `GitContext.discoverRoot(from:)`, the transcript under the working directory. A fixture driving `RunCommand` in-process inherits the test process's own cwd — this checkout — and so discovers all three the same way a real invocation would. Every one of them is live loss rather than noise: a proof burns one of a bounded set of record slots on a run that proved nothing about this tree, seeded timings are overwritten by any sibling fixture running in parallel, and a transcript evicts the developer's real ones, of which only ``RunLog/keptLogs`` are kept.
    ///
    /// **One seam, not one per destination.** A seam per destination is what let the last of them go unnoticed: two of them named the ledger and the durations store, and a fixture that set both still wrote its transcript into the checkout, because nothing about either said the transcript was a destination at all. A fixture now scopes the whole of a plain run or none of it, and a destination added to that path is scoped by construction.
    ///
    /// **A plain run is the whole of what it covers, and the other branches are not fixture-drivable at all.** `--without`, `--restore` and the set-aside watcher each return from `run()` before this is read, and each writes into the repository it discovers whatever it is set to: a set-aside moves the caller's uncommitted work out of that tree and back. Driving one of them in-process against a real checkout is not a fixture that needs scoping but a fixture that must not be written, and this seam is no defence against it.
    var writesUnder: URL?

    /// Where the answer goes — the wrapped command's passthrough, the filtered answer, and the raw-output fallback with its headline and device notes — injected so a test can read what a run printed.
    ///
    /// Defaulted to the standard streams, which is what every real invocation writes to. What is not a run's answer still goes to the standard streams directly: a refusal to start, the `--proved` verdict, and the notes the ledger and the durations store write about themselves.
    var output: CommandOutput = .standard

    /// How long ``RunInventoryCheck`` may spend bringing the index up to date and reconciling before it gives up and skips — injected so a test does not inherit the real budget's dependence on machine load.
    ///
    /// Defaulted to ``RunInventoryCheck/freshenBudget``, which is what every real invocation waits. A fixture that brings a fixture package's index up to date competes with everything else on the machine for the same CPU a full suite run is also using, so the wait it measures is not the work `--against` actually does; widening this seam lets a fixture assert the reconciled answer without being timed out by load that has nothing to do with the behaviour under test.
    var inventoryBudget: TimeInterval = RunInventoryCheck.freshenBudget

    /// How long the line under a refused `--filter` may take to find the suites before it is left out (``UnmatchedFilterHint/lookupBudget`` in every real invocation) — injected for the same reason as ``inventoryBudget``: a fixture's lookup competes with a loaded suite run for the CPU, and the wiring under test is not the wait.
    var hintBudget: TimeInterval = UnmatchedFilterHint.lookupBudget

    /// The environment ``RunLedger/switchName`` is read from — injected so a test can switch the ledger off for one run without setting a variable every suite running beside it would read.
    ///
    /// Defaulted to the process's own environment, which is what every real invocation reads.
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Ends the run's progress file with the exit code and log path — injected so a test can look at what the ledger holds when it happens.
    ///
    /// Defaulted to the progress file's own finish, which is every real invocation.
    var finishProgress: (RunProgress, Int32, String?) -> Void = { $0.finish(exitCode: $1, logPath: $2) }

    /// What was asked for, minus the terminator.
    ///
    /// `.captureForPassthrough` hands `--` through with everything else, and both spellings — with it and without — have to reach the same command.
    private var arguments: [String] {
        let written = command.first == "--" ? Array(command.dropFirst()) : command
        return coverage ? RunCoverage.enabling(written) : written
    }

    func run() throws {
        // `--root` is a query flag; here it would reach the wrapped command (`env` rejects it as an option).
        if arguments.first == "--root" {
            throw ValidationError("sift run takes no --root: it runs in the current directory, so cd into the worktree first.")
        }
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let guardSetAside {
            throw ExitCode(SetAsideGuardian.watch(recordID: guardSetAside, repositoryRoot: workingDirectory))
        }
        // Before every other reading of the line: a revision names which commit's version of a pathspec to
        // set aside, so with no pathspec it says nothing at all, and that is the caller's mistake to hear
        // whatever else they asked for.
        guard withoutLine.count <= 1 else {
            throw ValidationError("sift run --without-line takes one line per run, not \(withoutLine.count): \(withoutLine.joined(separator: ", ")).")
        }
        if !withoutLine.isEmpty, !without.isEmpty || since != nil || restore || proved {
            throw ValidationError("sift run --without-line takes no --without, --since, --restore or --proved: it sets aside one line of the working tree, and nothing else.")
        }
        let line = try withoutLine.first.map(Self.line(named:))
        try RunCoverage.validate(arguments, coverage: coverage, from: from, setsAside: !without.isEmpty || line != nil, restoresOrProves: restore || proved)
        guard since == nil || !without.isEmpty else {
            throw ValidationError(RunWithoutError.sinceWithoutPathspec.description)
        }
        if restore {
            guard arguments.isEmpty, without.isEmpty else {
                throw ValidationError("sift run --restore takes no command and no --without: it only puts back an earlier set-aside.")
            }
            try RunWithoutCommand.restore(in: workingDirectory)
            return
        }
        // Answered below as it stands, the pair would print the proved verdict with the set-aside silently
        // dropped, and exit 1 would read as "not proved" whichever question the script meant to ask.
        if proved, !without.isEmpty {
            throw ValidationError("sift run --proved takes no --without and no --since: asking whether a tree is proved is not a question about a change set aside.")
        }
        guard !arguments.isEmpty else {
            throw ValidationError(RunError.nothingToRun.description)
        }
        // `.captureForPassthrough` hands `-h` to the wrapped command, which is what makes it useful — but
        // with nothing else on the line there is no wrapped command, and `sift run --help` would exec
        // `/usr/bin/env --help` instead of describing this subcommand.
        if arguments == ["-h"] || arguments == ["--help"] {
            throw CleanExit.helpRequest(self)
        }
        // Every run, not only `--without`: while a set-aside is out of the tree, anything built from it is
        // not the caller's code. The root is found once, here, and handed on to the launcher. A run whose
        // writes are scoped is guarded on the repository they are scoped to, never on the process's own.
        let root = GitContext.discoverRoot(from: workingDirectory)
        // The checkout the command builds, which a `--package-path`, `-C` or `-project` can put outside `root`:
        // its set-aside refuses the run as `root`'s does, and a proof and the stop gate's green-build record are
        // of its tree and filed under it.
        let checkouts = RunCheckouts(arguments: arguments, workingDirectory: workingDirectory, launched: root)
        let builtRoot = checkouts.built
        try RunCoverage.validateRevision(from, in: builtRoot)
        let guardedRoots = [writesUnder ?? root] + (checkouts.buildsElsewhere ? [builtRoot] : [])
        if let refusal = guardedRoots.lazy.compactMap({ $0.flatMap(SetAsideSession.refusal(inRepository:)) }).first {
            StandardStreams.emitError("sift run: refusing to start — \(refusal.description)")
            // A plain run keeps the one failure code it has always had; `--without` answers in its own codes,
            // where a script has to be able to tell somebody's work being out of the tree from a busy tree.
            guard without.isEmpty, line == nil else {
                throw (refusal.workIsOut ? RunWithoutCommand.Exit.notBack : RunWithoutCommand.Exit.refused).code
            }
            throw ExitCode.failure
        }
        // Asking is not running, so it answers before anything is launched and after the guard above: a tree
        // with somebody's work set aside is not the tree the caller means, and neither question may be put on it.
        if proved {
            throw ExitCode(answerProved(checkouts, workingDirectory: workingDirectory))
        }
        if !without.isEmpty || line != nil {
            if let refusal = checkouts.setAsideRefusal(flag: line == nil ? "--without" : "--without-line") {
                throw ValidationError(refusal)
            }
            try RunWithoutCommand(
                arguments: arguments,
                pathspecs: without,
                line: line,
                since: since,
                runKey: { runKey(in: $0, from: workingDirectory) },
                file: { outcome, lines, milliseconds, startedOn in
                    record(outcome, answerLines: lines, milliseconds: milliseconds, startedOn: startedOn)
                }
            )
            .run(in: workingDirectory)
            return
        }
        // Before the command starts, because a key taken afterwards is a key for whatever the tree became
        // while the suite ran — an edit landing mid-run would otherwise be recorded as proved by a suite
        // that never read it. It is taken again at the end and the two must agree.
        let treeBefore = provableTree(in: builtRoot, from: workingDirectory)
        let coverageStart = coverage ? (tree: builtRoot.flatMap { TreeKey.of(repositoryRoot: $0) }, date: Date()) : nil
        let startedOn = runKey(in: builtRoot, from: workingDirectory)
        let started = Date()
        if coverage {
            XcodebuildCoverage.clearOwnResultBundle(for: arguments, in: workingDirectory)
        }
        // A run whose writes a fixture scoped is driven inside a test process, whose signals are not a run's to take.
        // The file carries the tree the run started on, only for a run of this repository: a `--package-path` run of another one would put that tree in this one's directory.
        let progress = RunProgress.forRun(
            in: root,
            writesUnder: writesUnder,
            environment: environment,
            tree: checkouts.buildsElsewhere ? nil : treeBefore?.tree.value
        )
        let interruptions = RunProgressInterruptions.watch(progress, arming: writesUnder == nil)
        defer { interruptions.end() }
        let outcome = try RunLauncher(workingDirectory: workingDirectory, repositoryRoot: root, runLogDirectory: writesUnder)
            .run(arguments, passingThrough: output.emitRaw, readingEventStream: true, progress: progress)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let selector = RunTestSelector.named(in: arguments)
        // A selected run that did not build has only its raw log to say what failed, so the log is taken out of
        // the count the next runs prune, into a pool of its own — before any line of the answer names it.
        if let report = outcome.report, selector?.didNotBuild(report, exitCode: outcome.exitCode) == true {
            outcome.log?.keep(in: .didNotBuild)
        }
        let bundles = RunTestBundles.declared(forRunOf: arguments, in: workingDirectory)
        let executedNothing = outcome.report.map { RunTestSelector.executedNothing($0, exitCode: outcome.exitCode, testBundles: bundles) } ?? false
        // A run that executed none of the tests it named proves nothing about this tree, whatever it exited, and
        // neither does an unselected one that executed none of the tests its package declares.
        let ownExitCode = outcome.report.flatMap { selector?.ownExitCode($0, exitCode: outcome.exitCode) }
            ?? (executedNothing ? RunTestSelector.exitCode : nil)
        let exitCode = ownExitCode ?? outcome.exitCode
        // After the run is measured and before the answer goes out. Measured before, because the milliseconds
        // in the run log are the wrapped command's and never this tool's own housekeeping; before the answer,
        // because what it found is a line of that answer and a qualification on its headline.
        // The log is read whole only where the re-arm has to consult it: an `xcodebuild` line that named no
        // `-destination`, whose resolved platform shows nowhere else. Every other run pays nothing for it.
        let needsTranscript = arguments.first.map { ($0 as NSString).lastPathComponent } == "xcodebuild" && !arguments.contains("-destination")
        // Lossy, not `String(data:encoding:)`: only an ASCII marker (`PLATFORM_NAME\=…`) is ever looked for in
        // this text, so a run log that is not valid UTF-8 elsewhere must not drop the re-arm note along with it.
        let transcript = needsTranscript ? outcome.log?.contents().map { String(decoding: $0, as: UTF8.self) } : nil // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
        let accessibility = SimulatorAccessibility.restore(after: arguments, log: transcript)
        let inventory = inventoryLines(outcome, workingDirectory: workingDirectory, root: root, executedNothing: executedNothing)
            + UnmatchedFilterHint.lines(after: outcome, selector: selector, repositoryRoot: writesUnder ?? root, budget: hintBudget)
        var answerLines = report(outcome, workingDirectory: workingDirectory, accessibility: accessibility, bundles: bundles, selector: selector, inventory: inventory)
        if let coverageStart {
            let section = coverageSection(checkouts, workingDirectory: workingDirectory, treeBefore: coverageStart.tree, started: coverageStart.date)
            section.forEach(output.emit)
            answerLines = answerLines.map { $0 + section.count }
        }
        record(outcome, answerLines: answerLines, milliseconds: elapsed, startedOn: startedOn)
        // Both keys, and they must agree: a tree edited while the command ran was read whole by neither
        // side of it, so a record of either key would stand for something never built or tested.
        let green = ownExitCode == nil && outcome.exitCode == 0
        if green || RunCommandKind.executesTests(arguments), let builtRoot, let treeBefore, TreeKey.of(repositoryRoot: builtRoot) == treeBefore.tree {
            if green {
                prove(outcome, bundles: bundles, selector: selector, ran: treeBefore, in: builtRoot, milliseconds: elapsed)
                recordGreenBuild(outcome, ran: treeBefore, in: builtRoot, milliseconds: elapsed)
            } else {
                recordFailure(outcome, ran: treeBefore, in: builtRoot, milliseconds: elapsed)
            }
        }
        // The progress file ends on sift's own verdict, once the log has settled where the answer will name it,
        // and after the ledger write above: a stop landing between the two would find no live run and no record.
        progress.map { finishProgress($0, exitCode, outcome.log?.url.path) }
        interruptions.end()
        seedDurations(outcome, in: builtRoot)
        // The two exit codes that are not the wrapped command's: see ``RunTestSelector/exitCode`` and
        // ``RunTestSelector/didNotBuildExitCode``.
        guard exitCode == 0 else {
            throw ExitCode(exitCode)
        }
    }

    /// Files this run in the per-user run log, after the answer has already gone out.
    ///
    /// After, deliberately: the answer is what the caller is waiting on, and the log is a tally nobody reads in the same second. It is best-effort on the same terms as the usage log — a failure notes itself on stderr and changes neither the output above it nor the exit code below it.
    ///
    /// The line counts and the failing tests answer to different rules, and taking one from the other is the mistake to avoid here: `answerLines` describes the *answer* — how many lines this command printed, which the fail-open branch reports as the whole transcript it served — while the failing tests describe the *run*, and are `nil` for exactly that branch, because a failure the filter could not explain is one nobody can name the tests of.
    private func record(_ outcome: RunOutcome, answerLines: Int?, milliseconds: Int, startedOn: TreeContentHash.RunKey?) {
        log.record(
            logKey: outcome.logKey,
            exitCode: outcome.exitCode,
            answer: RunUsageLog.Answer(
                report: outcome.report,
                lines: answerLines,
                failedTests: outcome.reportedTestFailures
            ),
            repositoryRoot: outcome.repositoryRoot,
            milliseconds: milliseconds,
            startedOn: startedOn
        )
    }

    /// The content this run starts on and the command it was given, for `flakes` to key its outcomes by — taken only where the run executes tests.
    ///
    /// A build, a linter or a passthrough can fail no test and a run outside a repository has no tree, so none of them pays for a hash nothing will read. Taken before the command starts for the reason ``provableTree(in:)`` is: afterwards it would be the tree the run left, not the one it read.
    private func runKey(in root: URL?, from workingDirectory: URL) -> TreeContentHash.RunKey? {
        guard let root, RunCommandKind.executesTests(arguments) else {
            return nil
        }
        return TreeContentHash.runKey(of: arguments, in: workingDirectory, repositoryRoot: root)
    }

    /// `workingDirectory`, relative to `root` — `"."` for the root itself, the same spelling ``TreeContentHash/invocation(of:in:repositoryRoot:)`` uses, so a nested package's suite and the whole repository's never stand for each other in the ledger while the same relative directory in a second worktree still matches.
    private static func directory(of workingDirectory: URL, relativeTo root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let directory = workingDirectory.resolvingSymlinksInPath().path
        return directory == rootPath ? "." : directory.hasPrefix(rootPath + "/") ? String(directory.dropFirst(rootPath.count + 1)) : directory
    }

    /// The `--coverage` section, measured in the checkout the command builds, whose history `--from` names and where `diff --coverage` looks for the record.
    ///
    /// A directory spelled through a variable names no checkout to measure against, so the section is one refusal saying so rather than a measurement of the checkout `sift run` was started in; one in no repository has no section, as a run outside a repository has none.
    private func coverageSection(_ checkouts: RunCheckouts, workingDirectory: URL, treeBefore: TreeKey?, started: Date) -> [String] {
        guard checkouts.builtDirectory != nil else {
            return CoverageAnswer.refused("the command names the directory it builds through a variable, so its coverage cannot be keyed to a checkout")
        }
        return RunCoverage.section(workingDirectory: workingDirectory, root: checkouts.built, arguments: arguments, from: from, treeBefore: treeBefore, started: started)
    }

    /// Seeds the durations store from an ordinary wrapped `xcodebuild test`, so a first sharded run is not planning blind.
    ///
    /// Silent on every way this can fail to apply — no repository, no test outcomes worth keeping, or the write itself failing: this is a bonus a plain run pays forward, never a reason to change what the run already reported or exited with.
    private func seedDurations(_ outcome: RunOutcome, in root: URL?) {
        guard let root = writesUnder ?? root,
              RunCommandKind.population(of: outcome.logKey) == "\(RunCommandKind.xcodebuild.label) test",
              let recording = outcome.report.flatMap({ TestDurationStore.Recording(wrappedRun: $0.testOutcomes, exitCode: outcome.exitCode) }),
              !recording.observations.isEmpty
        else {
            return
        }
        var store = TestDurationStore(repositoryRoot: root, note: { StandardStreams.emitError($0) })
        store.record(recording)
    }

    /// The tree this run is about to read and the directory it reads it from, taken only where a record could be written for it.
    ///
    /// Outside a repository, or for a command that neither builds nor tests, there is nothing to record and nothing to pay for: the key costs a `git add` over a scratch index, which is cheap but not free, and a run that can never be recorded must not pay it. Its readers are `prove(_:bundles:selector:ran:in:milliseconds:)`, which records only a run that executed tests, and `recordGreenBuild(_:ran:in:milliseconds:)`, which records any green build or test for the stop gate, and `recordFailure(_:ran:in:milliseconds:)`, which records a red run of tests — so a build pays for the key before it and the one after it, and a linter or a passthrough pays for neither.
    ///
    /// **With the ledger switched off a run of tests still pays for it**, because a red run must still withdraw the proof it contradicts: the switch is read per process, and a green filed with it on would otherwise outlive a red run with it off and answer the next `--proved` that has it on. Only a build is spared, since nothing it could file is allowed with the switch off.
    private func provableTree(in root: URL?, from workingDirectory: URL) -> ProvableRun? {
        guard let root,
              RunLedger.isOn(environment: environment) ? RunCommandKind.buildsOrTests(arguments) : RunCommandKind.executesTests(arguments)
        else {
            return nil
        }
        return TreeKey.of(repositoryRoot: root).map { ProvableRun(tree: $0, workingDirectory: Self.directory(of: workingDirectory, relativeTo: root)) }
    }

    /// The lines ``RunInventoryCheck`` owes this run's answer, and none for a run it does not bound.
    ///
    /// Read from the repository ``writesUnder`` names where a fixture scoped the run, since freshening an index is a write like the others that seam covers; a real invocation reads the repository it ran in.
    private func inventoryLines(_ outcome: RunOutcome, workingDirectory: URL, root: URL?, executedNothing: Bool) -> [String] {
        guard let report = outcome.report, let repository = writesUnder ?? root,
              RunInventoryCheck.applies(to: arguments, report: report, workingDirectory: writesUnder ?? workingDirectory, repositoryRoot: repository, executedNothing: executedNothing)
        else {
            return []
        }
        var outcomes = report.testOutcomes
        outcomes.commandExitCode = outcome.exitCode
        return RunInventoryCheck.check(outcomes, loggedAt: outcome.log?.url, repositoryRoot: repository, budget: inventoryBudget, executedNothing: executedNothing).lines(after: report.testCrash)
    }

    /// The ledger this run reads and writes: the real one for `root`, or the one under ``writesUnder`` where a test scoped this run.
    private func ledger(in root: URL, note: @escaping @Sendable (String) -> Void = { _ in }) -> RunLedger {
        RunLedger.inRepository(at: writesUnder ?? root, note: note)
    }

    /// Files this run as a green proof of the tree it read, when it is one.
    ///
    /// **Both keys, and they must agree.** `ran` is the tree as it stood when the command launched; the caller takes it again after, and a tree edited while the suite ran records nothing — the suite read neither of the two trees whole, and the later gate would otherwise skip on a proof of something that was never tested.
    ///
    /// Silent on every way it can fail to apply, like the durations it sits beside: a proof is a saving offered to a later gate, never a reason to change what this run reported or exited with. Every refusal here costs one suite run, which is the direction each of them is chosen to fail in.
    private func prove(_ outcome: RunOutcome, bundles: RunTestBundles, selector: RunTestSelector?, ran: ProvableRun, in root: URL, milliseconds: Int) {
        guard RunCommandKind.executesTests(arguments) else {
            return
        }
        // Exit 0 and still no proof — a pass read from a `-quiet` exit code, a declared bundle that never
        // reported: not green either, so an older green on the same content must not stand for it.
        guard outcome.provedGreen(testBundles: bundles, selector: selector) else {
            return recordFailure(outcome, ran: ran, in: root, milliseconds: milliseconds)
        }
        // Switched off, a green proves nothing; only the red above still lands.
        guard RunLedger.isOn(environment: environment), let toolchain = ToolchainIdentity.current() else {
            return
        }
        ledger(in: root, note: { StandardStreams.emitError($0) })
            .recordGreen(ledgerRecord(outcome, ran: ran, in: root, toolchain: toolchain.description, milliseconds: milliseconds))
    }

    /// Files this red run of tests in the ledger's ``RunLedger/failedRuns`` and drops the green runs of the same command on the same content it contradicts, so `--proved` does not stand on one.
    ///
    /// Red is anything but a green exit, this tool's own codes included: a run that failed, did not build, or executed none of the tests it named — and a run of tests that exited 0 without proving its tree, which `prove(_:bundles:selector:ran:in:milliseconds:)` hands here. The caller has already required the same tree before and after, since a failure on a tree that moved underneath it is evidence about neither tree. Best-effort like the proof: a red record that does not land costs nothing a caller saw.
    private func recordFailure(_ outcome: RunOutcome, ran: ProvableRun, in root: URL, milliseconds: Int) {
        guard let toolchain = ToolchainIdentity.current() else {
            return
        }
        ledger(in: root, note: { StandardStreams.emitError($0) })
            .recordFailure(ledgerRecord(outcome, ran: ran, in: root, toolchain: toolchain.description, milliseconds: milliseconds))
    }

    /// The record of this run on `ran`, finished now, as each of the ledgers files it.
    ///
    /// - Parameter keyed: Whether the command is the proof key (build-location options removed, ``ProofKey``) rather than argv as spelled, which is what the green-build record the stop gate reads keeps.
    private func ledgerRecord(_ outcome: RunOutcome, ran: ProvableRun, in root: URL, toolchain: String, milliseconds: Int, keyed: Bool = true) -> RunLedger.Record {
        RunLedger.Record(
            tree: ran.tree.value,
            command: keyed ? ProofKey.command(of: arguments) : arguments.joined(separator: " "),
            toolchain: toolchain,
            finishedAt: Date(),
            log: outcome.log?.url.lastPathComponent,
            milliseconds: milliseconds,
            checkout: root.path,
            workingDirectory: ran.workingDirectory
        )
    }

    /// Files this green build or test in the checkout's ``RunLedger/greenBuilds(inCheckout:)``, for the stop gate to find whatever shell the agent wrapped the run in.
    ///
    /// The run is the one party that knows its own exit status, directory and repository: a transcript sees only the call's, which a pipe into `tail` or a trailing `; echo $?` makes some other command's. The caller has already required exit 0, a selection that ran what it named, and the same tree before and after, so a failed or interrupted run, or one the tree moved under, records nothing.
    ///
    /// A run that skips the build compiled nothing, so it files no record here; it still proves, since the proved ledger answers whether this command passed on this tree's content, not whether the tree compiled.
    private func recordGreenBuild(_ outcome: RunOutcome, ran: ProvableRun, in root: URL, milliseconds: Int) {
        guard RunLedger.isOn(environment: environment), RunCommandKind.compilesTree(arguments) else {
            return
        }
        RunLedger.greenBuilds(inCheckout: writesUnder ?? root)
            .record(ledgerRecord(outcome, ran: ran, in: root, toolchain: "", milliseconds: milliseconds, keyed: false))
    }

    /// Answers whether this command is already proved on this tree, and returns the exit code the answer stands behind.
    ///
    /// Every way the question cannot be put — outside a repository, a command naming the directory it builds through a variable, a tree git will not hash, a toolchain that will not name itself, or the ledger switched off — is answered *not proved* with that reason in the line, never left to the caller to interpret. But those ways split into two exit codes, because they call for different action: a tree with no record of a passing run (exit 1) is fixed by running the command, while a question the ledger could not even be put (exit 2) is not — the ledger stays blind to that tree however many times the command runs, so a caller branching on the exit code runs the command instead of asking again.
    private func answerProved(_ checkouts: RunCheckouts, workingDirectory: URL) -> Int32 {
        let root = checkouts.built
        let command = arguments.joined(separator: " ")
        let proofCommand = ProofKey.command(of: arguments)
        let key = root.flatMap { TreeKey.of(repositoryRoot: $0) }
        let answer: ProvedRunAnswer
        if let root, let key, let toolchain = ToolchainIdentity.current() {
            let ledger = ledger(in: root)
            let directory = Self.directory(of: workingDirectory, relativeTo: root)
            let trust = ledger.trust(tree: key, command: proofCommand, toolchain: toolchain, workingDirectory: directory, environment: environment)
            // Looked for only where no record of this tree exists: every other answer is about a record of this very tree.
            let lastGreen = trust == .notProved(.noRecord) ? ledger.lastGreen(of: proofCommand, workingDirectory: directory) : nil
            let nearest = trust == .notProved(.noRecord) ? ledger.nearestGreen(tree: key, otherThan: proofCommand, workingDirectory: directory) : nil
            answer = ProvedRunAnswer(
                treeKey: key,
                command: command,
                trust: trust,
                lastGreen: lastGreen,
                nearestOtherProof: nearest,
                changedSinceLastGreen: lastGreen.flatMap { key.changedPaths(since: TreeKey(value: $0.tree), repositoryRoot: root) },
                workingDirectory: directory
            )
        } else {
            let why = if checkouts.builtDirectory == nil {
                "the command names the directory it builds through a variable"
            } else if root == nil {
                "this is not a git repository"
            } else {
                key == nil ? "git would not hash this working tree" : "no Swift toolchain on PATH would name itself"
            }
            answer = ProvedRunAnswer(treeKey: key, command: command, trust: .notProved(.cannotAsk(why)))
        }
        StandardStreams.emit(answer.text)
        if answer.isProved {
            return 0
        }
        return answer.cannotTell ? 2 : 1
    }

    /// Serves the filtered answer, or the raw log when there is no honest filtered answer to serve, and reports how many lines the caller was handed.
    ///
    /// That count is what the run log files as this run's `shown`, and it is taken from the thing that was printed rather than from anything counted on the way to it. `nil` where there is no measurement to make: a passthrough filtered nothing, and the two error branches below served no answer at all — the accessibility notes they still print are the one thing they handed the caller, and a `shown` of 1 beside a log nobody was served would read as a saving that never happened. The fail-open branch reports the whole transcript's length *and* those notes, because that is honestly what it printed — a run that served its raw log saved nothing, and recording the filtered answer it never printed would put a saving in the ledger that never happened.
    ///
    /// - Parameter selector: The tests argv named to run, so a run that executed none of them answers `✘`.
    /// - Parameter bundles: What the package's manifest says this run was owed, read by the caller because that is where argv is: what `swift test` was pointed at decides whether the manifest beside the reader is the package that ran. The same value decides whether the run may stand for its tree, and one reading serves both.
    /// - Parameter inventory: What ``RunInventoryCheck`` said about the run, which only the filtered answer carries.
    func report(_ outcome: RunOutcome, workingDirectory: URL, accessibility: [SimulatorAccessibility.Restoration], bundles: RunTestBundles, selector: RunTestSelector?, inventory: [String] = []) -> Int? {
        guard outcome.kind.isFiltered else {
            output.emitError("sift run: no filter for this command — output passed through unchanged.")
            return nil
        }
        if let answer = outcome.filteredAnswer(workingDirectory: workingDirectory, accessibility: accessibility, testBundles: bundles, selector: selector, inventory: inventory) {
            output.emit(answer.text)
            return answer.lines
        }
        // Every path below this serves the raw log or nothing at all, so none of them renders a line about the
        // devices. The notes are owed by the run rather than by the answer that could be made of it, and they
        // are the last thing printed either way. The outcome's own report — parsed before the filtered answer
        // was refused — still says whether its failures have the shape of an empty accessibility tree, so an
        // already-on device is not told there is nothing to say when there is.
        let notes = Self.accessibilityNotes(for: outcome, workingDirectory: workingDirectory, accessibility: accessibility)
        defer {
            for note in notes {
                output.emit(note)
            }
        }
        // The command failed and the filter found nothing that says why. A short "no errors" over a
        // nonzero exit is the one answer this must never give, so the whole transcript goes out instead.
        // The two ways that can fail are different problems and must not share a sentence: no log was ever
        // opened, or one was and its bytes would not come back. Blaming a write for a failed read sends a
        // reader looking for a permissions problem that is not there.
        // `transcript`, not `log`: this is the raw output of this one run, and ``log`` on this command is
        // the per-user tally the run files itself in. The two are different files with different lifetimes.
        guard let transcript = outcome.log else {
            output.emitError("sift run: the filter found nothing that explains the failure, and no raw log could be opened for this run — re-run the command without `sift run`.")
            return nil
        }
        guard let raw = transcript.contents() else {
            output.emitError("sift run: the filter found nothing that explains the failure, and its raw log at \(transcript.url.path) could not be read — read that file, or re-run the command without `sift run`.")
            return nil
        }
        // A selected run whose build failed before any test ran is not "nothing that explains the failure":
        // `RunTestSelector` already knows that much with no error line to point at, and the raw log going out
        // anyway must not contradict it.
        if let headline = outcome.didNotBuildFallbackHeadline(selector: selector) {
            output.emitError(headline)
        } else {
            output.emitError("sift run: the filter found nothing that explains the failure — raw output follows.")
        }
        output.emitRaw(RunReportRenderer.clippingLongLines(of: raw, log: transcript.url))
        // The notes above are lines this run printed too, so the count that goes into the run log counts them
        // — the same arithmetic the filtered answer's receipt does, on the one path where the answer is the
        // whole transcript rather than a summary of it.
        return outcome.report.map { $0.totalLines + notes.count }
    }
}

extension RunCommand {
    /// The tree a run is about to read, bundled with the repository-relative directory it reads it from.
    ///
    /// The two travel together because a proof must agree on both: a suite run from a nested package's directory and one run at the repository root are different runs of the same argv, however identical their tree.
    private struct ProvableRun: Equatable {
        let tree: TreeKey
        let workingDirectory: String
    }
}

extension RunCommand {
    /// The device notes owed by a run whose filtered answer could not be served — read from the outcome's own report rather than assumed, so an already-on device is not told there is nothing to say when its failures read empty accessibility trees.
    ///
    /// Pulled out of ``report(_:workingDirectory:accessibility:bundles:)`` so the wiring — that ``RunOutcome/failuresReadEmptyTrees(workingDirectory:accessibility:)`` is asked rather than assumed `false` — is reachable from a test without a live process.
    static func accessibilityNotes(for outcome: RunOutcome, workingDirectory: URL, accessibility: [SimulatorAccessibility.Restoration]) -> [String] {
        let failuresReadEmptyTrees = outcome.failuresReadEmptyTrees(workingDirectory: workingDirectory, accessibility: accessibility)
        return accessibility.compactMap { $0.note(failuresReadEmptyTrees: failuresReadEmptyTrees) }
    }
}

extension RunCommand {
    /// The file and line `--without-line` names, split on the last colon; anything else is refused with the form it takes.
    private static func line(named written: String) throws -> (path: String, number: Int) {
        guard let colon = written.lastIndex(of: ":"),
              colon != written.startIndex,
              let number = Int(written[written.index(after: colon)...])
        else {
            throw ValidationError("sift run --without-line takes <file>:<line> — a Swift file and the number of the line to comment out, e.g. Sources/Widget.swift:42 — not \"\(written)\".")
        }
        return (String(written[..<colon]), number)
    }

    /// Only `command` comes off the command line.
    ///
    /// Spelled out because `ParsableCommand` is `Decodable` and its conformance is synthesized: a stored property that is not an argument would otherwise have to be `Decodable` too, and a log is not something a decoder can produce. Naming the keys leaves ``log`` to its default, which is exactly what the parse path wants.
    enum CodingKeys: String, CodingKey {
        case command
        case without
        case withoutLine
        case since
        case restore
        case proved
        case guardSetAside
        case coverage
        case from
    }
}
