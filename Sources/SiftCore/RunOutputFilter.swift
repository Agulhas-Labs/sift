//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads a toolchain's output one line at a time and keeps only what a caller has to act on.
///
/// Line-oriented and single-pass by design: the input is a stream that arrives while the build runs and can reach tens of megabytes, so nothing is held but the diagnostics themselves and one partial line. The shapes it reads are `swift build`, `swift test` and `xcodebuild`; which of those it was handed is the launcher's business, not this type's, because the parsing is the same for all three.
public struct RunOutputFilter {
    /// How many distinct warnings are listed before the rest are counted instead.
    ///
    /// A build that warns three hundred times is telling the caller one thing, not three hundred; the cap keeps that from crowding out the errors standing next to it.
    public static let warningCap = 20

    /// How many lines a parameterized failure's arguments may run across before the line naming its location is given up on — see ``continueOpenIssue(_:)``.
    ///
    /// A bound on memory, not a guess at how long a value is: a fixture string passed as an argument runs to dozens of lines, and a cap of 16 listed such a failure with no location and no message. The hold ends at the next event well before this in any log that has one.
    private static let openIssueLineCap = 2000

    /// How many lines beneath a test failure's own message — `↳` or merely indented — are kept in its note, each on a line of its own, before the rest are counted instead.
    ///
    /// A failure's message can end on a colon and open a list the same way a build error's can (see ``RunDiagnosticRecord``), and the line that answers the question is not always the `↳` comment itself: `Expectation failed: wrong.isEmpty` / `↳ 1 citation(s) name a line their rule is not on: (by adjacency)` / an indented line naming the actual citation is three lines, the third of them carrying no marker at all, and dropping it is dropping the answer. Twelve holds a hygiene test's to-do list (a `↳` line and its `path:line  name` entries) whole, so the list that was the answer is not left to the raw log, without letting an unrelated indented dump — a stack trace, a JSON blob a test printed on failure — grow a note without bound.
    private static let noteContinuationCap = 12

    /// What the invoked command committed to printing, so an absent verdict is recognisable as absent.
    ///
    /// Held from construction rather than worked out at the end because it comes from argv, which the stream never carries: reading the expectation out of the output it is supposed to judge would only ever agree with it.
    ///
    /// **Not optional, and that is the point.** ``RunVerdict/Contract/of(_:)`` answers `nil` for a command nobody modelled, and a `nil` here would fall through to the `declares` path with nothing owed — which makes ``RunVerdict/answersTheInvokedCommand`` vacuously true and hands the run whichever `** … SUCCEEDED **` the log turned up, the exact reading ``RunVerdict/Contract/unreadable`` exists to forbid. `RunLauncher` never filters a command with no contract, but an invariant that lives in the caller is not a property of the type. Mapping "no contract" to ``RunVerdict/Contract/unreadable`` at the boundary makes the safe reading the type's own property.
    private let contract: RunVerdict.Contract
    /// Whether the invocation asked `xcodebuild` for `-quiet` — read from argv for the reason ``contract`` is (``RunVerdict/Contract/isQuietXcodebuild(_:)``).
    ///
    /// The one thing that lets a log with no verdict be read as a pass. `-quiet` suppresses the success banner, so under it silence is the shape a clean run takes; without it, silence is a log that stopped before its end. Nothing in the two logs looks different, so the difference has to come from the invocation.
    private let quiet: Bool
    /// Whether the invocation asked `swift test` for `--parallel` — read from argv for the reason ``quiet`` is.
    ///
    /// Under `--parallel` SwiftPM prints no `Test Suite 'All tests' started at` and no `Executed …` for the tests it ran in parallel — only `[k/N] Testing <name>` progress lines, which this filter does not count — and, on a failure, reruns the failing test alone and prints XCTest's ordinary lines for that lone rerun. So a passing run under the flag carries no XCTest count at all, and a failing one carries a count of the rerun rather than of the run; a totals line built from that alone would report a package of four as `Swift Testing 0 tests in 0 suites`, or as `XCTest 1 test, 1 failure` for a run of four. Kept so the totals line can say why an XCTest count is missing or short rather than passing either off as complete.
    private let parallelSwiftTest: Bool

    private var lineBuffer = RunOutputLines()
    private var totalLines = 0
    private var diagnostics = RunDiagnosticRecord()
    private var testFailures: [RunTestFailure] = []
    private var failedTestNames: Set<String> = []
    private var reportedTestNames: Set<String> = []
    private var eventStreamNote: String?
    private var streamedTestIDs: Set<String>?
    private var buildSummary: String?
    /// Every XCTest closing counter the output carried, one per test process, in the order it printed them.
    ///
    /// A list rather than the last one, for the reason ``swiftTestingSummaries`` is one: `xcodebuild` runs one test process per bundle and each closes with its own `Executed …` total, so a two-bundle run prints two. Keeping only the last would put a passing bundle's count in the answer over a failing one's — `Executed 4 tests, with 0 failures (0 unexpected)` printed directly beneath `✘ xcodebuild — exit 65`, with the `Executed 12 tests, with 3 failures` from the bundle that actually failed nowhere in it. The Swift Testing two-bundle capture cannot catch it: both its `Executed` lines are the `0 tests` boilerplate below.
    private var xctestSummaries: [String] = []
    /// How many XCTest test processes the output announced — one `Test Suite 'All tests' started at` each, counted rather than only used as a boundary.
    ///
    /// Half of what a tally is owed from — see ``swiftTestingProcessOpenings`` for the other, and ``RunReport/testProcessOpenings`` for the two summed and for what neither can say.
    private var xctestProcessOpenings = 0
    /// How many of the closing counters XCTest printed actually closed a process, vestigial or not.
    ///
    /// A separate count from ``xctestSummaries``, which drops a closing counter that states nothing (``isVestigialCounter(_:)``) so the answer does not print `XCTest 0 tests, 0 failures` over a package that holds none — a choice about what to *show*, not about whether the process announced itself as done. A process that prints only that counter still closed; a process that crashed before printing it did not, and this is what tells the two apart for ``RunReport/testProcessClosings``.
    private var xctestProcessClosings = 0
    /// How many `swiftpm-testing-helper` processes the output announced — one `Test run started.` each.
    ///
    /// `swift test` runs this process, which carries every `@Test`, alongside and separately from the XCTest harness that carries every `XCTestCase`: a crash probe kills one while the other completes, and the error `xcodebuild`/`swift test` prints on a crash of this one names it by path. So the two are counted the same way and summed, never folded into one population by assuming a single process prints one of each.
    private var swiftTestingProcessOpenings = 0
    /// How many XCTest processes printed the end of their outermost suite — `Test Suite 'All tests'` or `'Selected tests'` `passed at`/`failed at` — which is the process finishing every test it was given.
    ///
    /// Not ``xctestProcessClosings``, which counts a process closed on the first counter it prints — the innermost suite's. A process that dies after one suite has finished has printed that counter and never this line, and ``xctestOnlyVerdict()`` reads a pass only where every process that opened printed it.
    private var xctestOuterSuiteEndings = 0
    /// Whether the next `Executed …` line opens a new tally rather than restating the one in hand.
    ///
    /// Within one test process the counter is printed once per suite, once per bundle and once for the run, and the last of those is the process's own total — so last-wins is right *inside* a process and wrong across two. The boundary is the process announcing itself, which XCTest does exactly once per run of it (measured: once in every single-bundle capture in the corpus, twice in each two-bundle one).
    private var xctestBundleIsNew = true
    /// Every Swift Testing run tally the output carried, in the order it printed them.
    ///
    /// A list rather than the last one, because a run can hold more than one and the last of them speaks for a fraction of it. Swift Testing prints one tally per test *process* and `xcodebuild` runs one process per test bundle, so a two-target scheme closes with two — and keeping only the second would put one bundle's counts in the answer over a census that had counted both: `Swift Testing: 0 failures, 1 known issue` printed directly above `2 failures`, and `7 tests in 2 suites` for a run of 19 tests in 5.
    private var swiftTestingSummaries: [String] = []
    /// Whether XCTest's half of the run reported anything failing — its own closing counter, or an assertion this filter read off it.
    ///
    /// Kept because Swift Testing's closing sentence is not a statement about the whole run. It prints `Test run with 0 tests in 0 suites passed after 0.001 seconds.` on a package that contains no `@Test` at all, so a `swift test` judged on that sentence alone would report a package whose only `XCTestCase` had just failed as a pass — a tick standing directly above the assertion the answer had itself just listed.
    ///
    /// Evidence rather than a summary, so it never expires: XCTest prints its counter once per suite and once for the run, and a suite that failed is a fact about the run whatever the aggregate after it says.
    private var xctestFailed = false
    /// Whether the log printed `xcodebuild`'s own `Testing cancelled because the build failed.` — positive evidence that the build, not a test, is why nothing ran, for a build failure whose compiler error carries no `file:line` (a signing failure, a missing build input file) and so leaves ``errors`` with nothing ``RunTestSelector/didNotBuild(_:exitCode:)`` can key on.
    private var cancelledForBuildFailure = false
    /// Whether the log printed `xcodebuild`'s own `Failing tests:` heading — proof that a named test failed, which vetoes ``RunTestSelector/didNotBuild(_:exitCode:)`` even where a `-quiet` run's own failure line otherwise reads like a compiler error with a `file:line`.
    private var namedFailingTests = false
    /// Which recorded failure a `↳` comment on the very next line would belong to, if one arrives.
    private var unnotedFailure: Int?
    /// How many continuation lines have already been folded into each failure's note, keyed by its index in ``testFailures``.
    ///
    /// Kept apart from the note itself because the cap (``noteContinuationCap``) counts lines read, not characters kept — a `nil` entry and an entry of `0` read the same way, so this is consulted only while ``unnotedFailure`` still names the index.
    private var noteLinesKept: [Int: Int] = [:]
    /// How many continuation lines past the cap have been counted for each failure, keyed the same way, and folded into its note as one elision once the chain ends.
    private var noteLinesElided: [Int: Int] = [:]
    /// Every continuation line of the note still arriving, kept only while the failure it belongs to is a `.contains`/`.hasPrefix`/`.hasSuffix` — the haystack ``RunFailureCensus/closestLine(message:note:truncated:)`` searches once the note ends — up to ``RunFailureCensus/closestLineNoteLimit``, and whether the limit cut it short.
    private var containmentNote: ContainmentNote?
    /// A whitespace-only line that arrived while a failure's note was open, held until the next line says whether the note goes on past it.
    ///
    /// Swift Testing prints an empty line inside a multi-line value or comment as an indented line with nothing on it, and the note continues beneath it; read as the end of the note, it cut the haystack short and left the search to call a line missing that was two lines further down. Held rather than folded, because only the line after it can tell a blank inside a note from one that ends it: the note goes on across it only where that line is itself a plain continuation.
    private var heldBlank: (index: Int, line: String)?
    /// A `recorded an issue with 1 argument …` line whose argument value broke across lines, held until the line carrying its location arrives.
    private var openIssue: OpenIssue?
    /// Every test a start line read from its own head has named, which a glued ending or issue must name to be split off (``RunGluedTestLine``).
    private var startedFromHead: Set<String> = []
    /// Whether the line being read is the framework's line split off a glued one, whose start, if it is one, opens no test for a later glued line.
    private var readingGluedRest = false
    /// Every test the run started and finished, passes included — what `run --without` compares two runs by.
    private var outcomes = RunTestOutcomes()
    /// The compiler crash the log reports, read before any other reader sees a line of it.
    private var compilerCrash = RunCompilerCrash.Reader()
    /// The test process that died on a signal, read under `swift test`'s contract only.
    private var testCrash = RunTestCrash.Reader()
    /// The Swift Testing tests the run's event stream declared, by the name the console prints, under the test target that holds them, or `nil` where no stream was read.
    private var declaredSwiftTesting: [String: [String]]?
    /// Where each Swift Testing test the run's event stream started and never ended was declared.
    private var unfinishedSources: [DeclaredTestSource] = []

    public init(expecting contract: RunVerdict.Contract) {
        self.init(expecting: contract, quiet: false, parallelSwiftTest: false)
    }

    /// A filter for the command `arguments` runs, its contract, its `-quiet` and its `--parallel` all read from them — the reading `RunLauncher` makes, kept in one place so a test that states an invocation gets exactly what production would.
    ///
    /// A command with no contract at all maps to ``RunVerdict/Contract/unreadable`` here, for the reason ``contract`` gives.
    ///
    /// `linters` carries the extra linter executable names the repository configured, for the same reason ``RunCommandKind/recognize(_:linters:)`` takes them: the contract is decided by the kind, so a filter told less than the launcher was would read a configured linter's output under no contract at all.
    public init(invokedAs arguments: [String], linters: Set<String> = []) {
        self.init(
            expecting: RunVerdict.Contract.of(arguments, linters: linters) ?? .unreadable,
            quiet: RunVerdict.Contract.isQuietXcodebuild(arguments),
            parallelSwiftTest: arguments.contains("--parallel")
        )
    }

    private init(expecting contract: RunVerdict.Contract, quiet: Bool, parallelSwiftTest: Bool) {
        self.contract = contract
        self.quiet = quiet
        self.parallelSwiftTest = parallelSwiftTest
    }
}

public extension RunOutputFilter {
    /// Feeds a chunk of raw bytes; whatever trailing partial line it ends on is held for the next chunk.
    mutating func consume(_ data: Data) {
        for line in lineBuffer.split(data) {
            consume(line: line)
        }
    }

    /// Reads the Swift Testing event stream the run wrote beside its console, once every line of the console has been fed: the endings and failing tests the console lost are taken from it, where the two disagree — see ``RunEventStreamFold``.
    mutating func read(eventStream stream: ShardEventStream) {
        // A console that ended without a newline still holds its last line, which may be an ending the stream would otherwise be counted against.
        if let trailing = lineBuffer.remainder() {
            consume(line: trailing)
        }
        streamedTestIDs = stream.recordedIDs
        unfinishedSources = stream.unfinishedSources
        declaredSwiftTesting = Dictionary(grouping: stream.declared, by: \.target).mapValues { $0.map { stream.printedNames[$0] ?? $0.function } }
        guard let fold = RunEventStreamFold.of(stream, console: outcomes, named: failedTestNames.union(reportedTestNames)) else {
            return
        }
        for ending in fold.endings {
            outcomes.recordStreamed(ending.attempt, of: ending.name)
        }
        for name in fold.failedNames {
            append(RunTestFailure(name: name, location: nil, message: fold.messages[name] ?? "failed, recorded in the event stream — the console relayed none of its lines"))
        }
        eventStreamNote = fold.note
    }

    /// Feeds one complete line, already stripped of its newline.
    ///
    /// ``RunOutputLines/outputBarrier`` comes off the head here (``RunOutputLines/cleaned(_:)``), before any reader sees the line, because every one of them anchors on the line's first characters and none of them is the place to know about a barrier.
    ///
    /// ANSI escapes come off here too, before anything else reads the line. Swift 6.4's SwiftPM colours a compiler diagnostic even when stdout is a pipe — `path:line:col: \e[1;31merror: \e[1;39mcannot find 'ShellWord' in scope` — and every reader below anchors on a line's first characters or matches a fixed sentence inside it, neither of which survives an escape sitting in front of it. Stripping once, here, means every diagnostic, summary and test outcome this filter keeps is already clean — there is no second place that has to remember to do it for whatever it prints back.
    mutating func consume(line raw: String) {
        let line = RunOutputLines.cleaned(raw)
        if let (notice, rest) = Self.splitLockNotice(line) {
            consume(line: notice)
            consume(line: rest)
            return
        }
        if let (output, rest) = RunGluedTestLine.split(line, started: startedFromHead.contains) {
            consume(line: output)
            readingGluedRest = true
            consume(line: rest)
            readingGluedRest = false
            return
        }
        if !readingGluedRest, let name = RunGluedTestLine.startedTest(in: line) {
            startedFromHead.insert(name)
        }
        totalLines += 1
        let trimmedForMarkers = line.trimmingCharacters(in: .whitespaces)
        if trimmedForMarkers == "Testing cancelled because the build failed." {
            cancelledForBuildFailure = true
        } else if trimmedForMarkers == "Failing tests:" {
            namedFailingTests = true
        }
        // A `↳` comment belongs to the failure printed on the line directly above it and to nothing else —
        // the same marker heads the run's own preamble (`↳ Testing Library Version: 1902`) — so the claim
        // on it expires here, the moment any other line arrives.
        var noted = unnotedFailure
        unnotedFailure = nil
        if let held = heldBlank {
            heldBlank = nil
            if plainContinuation(in: line) != nil || Self.isBlank(line) {
                foldNoteLine("", marked: false, into: held.index)
                unnotedFailure = nil
                noted = held.index
            } else {
                closeNote(for: held.index)
                diagnostics.record(held.line)
            }
        }
        // An observer, not a reader that claims the line: a test's finishing line is read here and still
        // reaches the readers below, which is how a failure keeps its place in the listing as well. A line
        // of an open note is the author's text whatever it says, so it is no test's ending.
        if noted == nil || quotedContinuation(in: line) == nil {
            outcomes.read(line)
        }
        // Only while the build runs: the compiler never runs once a test has, so a crash's sentences after that
        // are a test's own text whatever they quote, in an open note or in an assertion's unmarked continuation.
        if noted == nil, openIssue == nil, !testsStarted, compilerCrash.read(line) {
            diagnostics.endColonContinuation()
            return
        }
        if continueOpenIssue(line) {
            return
        }
        // A note's own lines are the test's text; a line that is neither marked nor indented ends the note, and the
        // runtime prints its trap that way straight after an issue's `↳` lines.
        if contract == .runTally, noted == nil || (markedContinuation(in: line) == nil && plainContinuation(in: line) == nil), testCrash.read(line) {
            if let noted {
                closeNote(for: noted)
            }
            return
        }
        if diagnostics.continueLinkerBlock(line) {
            if let noted {
                closeNote(for: noted)
            }
            return
        }
        if diagnostics.startLinkerBlock(line) {
            if let noted {
                closeNote(for: noted)
            }
            return
        }
        if recordMarkedNote(line, on: noted) {
            return
        }
        if recordQuotedLine(line, on: noted) {
            return
        }
        if recordSummary(line) {
            if let noted {
                closeNote(for: noted)
            }
            return
        }
        if recordTestOutcome(line) {
            if let noted {
                closeNote(for: noted)
            }
            return
        }
        if let noted, Self.isBlank(line) {
            heldBlank = (noted, line)
            return
        }
        if recordPlainContinuation(line, on: noted) {
            return
        }
        if let noted {
            closeNote(for: noted)
        }
        diagnostics.record(line)
    }

    /// SwiftPM's notice that another process holds the `.build` lock and the line it was glued to, or `nil` where `line` does not open on one with more after it.
    ///
    /// SwiftPM writes the notice to standard error with no newline — `… waiting until that process has finished execution...` while it waits, ``… but this will be ignored since `--ignore-lock` has been passed`` when it will not — so in a log of both streams it heads the next line the run prints, which under `swift test` is a test process's opening: `Test Suite 'All tests' started at` or `Test run started.`. Every reader anchors on a line's start, so an opening glued there went uncounted.
    static func splitLockNotice(_ line: String) -> (notice: String, rest: String)? {
        guard line.hasPrefix("Another instance of SwiftPM") else {
            return nil
        }
        let endings = ["waiting until that process has finished execution...", "but this will be ignored since `--ignore-lock` has been passed"]
        guard let end = endings.lazy.compactMap({ line.range(of: $0)?.upperBound }).first, end < line.endIndex else {
            return nil
        }
        return (notice: String(line[..<end]), rest: String(line[end...]))
    }

    /// Closes the stream and returns what survived it.
    ///
    /// `exitCode` is the wrapped command's own, known only once it has ended — `nil` where a caller has none to give, which reads exactly as it always has: a `.declares` contract with no verdict line stays unverdicted. Given one, for an `xcodebuild -quiet` invocation, it is the one thing that lets silence itself be read as success (see ``verdict(from:exitCode:)``), and never anything else: it is compared, never trusted to explain a failure the log did not otherwise report.
    mutating func finish(exitCode: Int32? = nil) -> RunReport {
        if let trailing = lineBuffer.remainder() {
            consume(line: trailing)
        }
        if let open = openIssue {
            openIssue = nil
            appendUnlocated(open)
        }
        diagnostics.closeLinkerBlock()
        if let unnotedFailure {
            closeNote(for: unnotedFailure)
        }
        if let held = heldBlank {
            heldBlank = nil
            closeNote(for: held.index)
            diagnostics.record(held.line)
        }
        diagnostics.closeExpansion()
        appendUnexplainedFailures()
        let tally = soleTally()
        return RunReport(
            errors: diagnostics.errors,
            warnings: diagnostics.warnings,
            testFailures: testFailures,
            summaryLines: [buildSummary].compactMap(\.self) + xctestSummaries + swiftTestingSummaries,
            contract: contract,
            verdict: verdict(from: tally, exitCode: exitCode),
            tally: tally,
            totalLines: totalLines,
            testOutcomes: outcomes,
            testProcessOpenings: xctestProcessOpenings + swiftTestingProcessOpenings,
            testProcessClosings: xctestProcessClosings + swiftTestingSummaries.count,
            parallelSwiftTest: parallelSwiftTest,
            cancelledForBuildFailure: cancelledForBuildFailure,
            namedFailingTests: namedFailingTests,
            swiftTestingProcessOpenings: swiftTestingProcessOpenings,
            compilerCrash: compilerCrash.result,
            eventStreamNote: eventStreamNote,
            streamedTestIDs: streamedTestIDs,
            testCrash: settledTestCrash(exitCode: exitCode)
        )
    }

    /// The test crash the log reported, settled against every outcome the run read and the stream's declared tests, or, under `swift test`'s contract only, the tests a process that ended with no signal line left unfinished (``RunTestCrash/Reader/unsignalled(exitCode:outcomes:xctestUnclosed:)``); `nil` where the run exited 0, since a process that died fails `swift test`, so a signal line in a passing run is a test's printed text.
    private func settledTestCrash(exitCode: Int32?) -> RunTestCrash? {
        guard exitCode != 0, var crash = testCrash.result else {
            guard contract == .runTally else {
                return nil
            }
            return testCrash.unsignalled(exitCode: exitCode, outcomes: outcomes, xctestUnclosed: xctestProcessOpenings > xctestOuterSuiteEndings)
        }
        crash.declaredSwiftTesting = declaredSwiftTesting
        crash.unfinishedSources = unfinishedSources
        return crash.settled(by: outcomes)
    }

    /// Whether the log has shown any test starting, running or failing — past which the build, and any compiler crash in it, is over.
    private var testsStarted: Bool {
        !outcomes.isEmpty || !outcomes.swiftTestingRuns.isEmpty || outcomes.parallelLines > 0 || outcomes.parallelSuiteStarts > 0
            || xctestProcessOpenings > 0 || swiftTestingProcessOpenings > 0 || !testFailures.isEmpty
    }

    /// `line` with every ANSI escape sequence removed: CSI (`ESC [` … a final byte, parameter bytes `0`–`?` and intermediate bytes ` `–`/` in between — the general shape, of which SGR colour is one case) and OSC (`ESC ]` … `ESC \` or a bell, which is how the compiler wraps a diagnostic's documentation link around its own tag — `[#\e]8;;URL\e\Tag\e]8;;\e\]` prints as `[#Tag]` once both are gone).
    ///
    /// A general CSI match, not an SGR-only one (`ESC [ … m`): the two cost the same regex, and the wider one needs no revisiting if a future toolchain starts writing cursor or erase sequences into a piped log the way Swift 6.4 now writes colour into one.
    ///
    /// **Called on every line, so a line with nothing to strip costs one byte scan.** Almost no line in a build log carries an escape, and building and running two regexes over each one is where a long log's time would go; every sequence either pattern matches opens on ESC, so a line without that byte is returned as it came. The regexes stay literals in the body rather than `static let`s: `Regex` is not `Sendable`, so a stored static of one is refused under strict concurrency, and behind this guard they are only built for a line that has something to strip.
    static func strippedOfANSIEscapes(_ line: String) -> String {
        guard line.utf8.contains(0x1B) else {
            return line
        }
        return line
            .replacing(#/\x1B\[[0-?]*[ -\/]*[@-~]/#, with: "")
            .replacing(#/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?/#, with: "")
    }
}

// MARK: - Decoration

extension RunOutputFilter {
    /// `text` with the status decoration Swift Testing writes in front of its lines removed, so what remains can be read from its first character.
    ///
    /// **Dropped by category rather than by enumerating glyphs.** Every one of these lines opens with a status glyph and whitespace, and which glyph depends on the terminal Swift Testing thinks it is writing to — `✘` in the `xcodebuild` captures, a private-use SF Symbol under `swift test` — with a zero-width space in front of it on some lines and not others in the same run. None of them is a letter or a digit, and the word that follows always is, so a run of neither is exactly the decoration.
    ///
    /// It is shared by the two readers that have to anchor on a first word — the run tally and a test's name — because the alternative is two spellings of one rule, and drift between them is how a quoted tally gets read as a real one.
    static func undecorated(_ text: String) -> Substring {
        text.drop { !$0.isLetter && !$0.isNumber }
    }
}

// MARK: - Summaries

extension RunOutputFilter {
    /// The tool's own closing counts, kept verbatim — a count this filter worked out itself would be a second thing to be wrong about.
    ///
    /// **Every one of these is anchored on the start of the line**, once the decoration in front of it has been dropped, and the run tally is the one that has to be. This reader runs before the one that reads failures, so a tally matched *anywhere* in the line would swallow any failure whose own message quoted the sentence: a mangled fragment of it filed as a tally, the tally count reaching two making ``soleTally()`` `nil`, and a run whose log plainly closes on `Test run with 2 tests in 1 suite failed after 0.001 seconds with 2 issues.` headlined `⚠ … no verdict in the log` while the real failure lost its message. Self-referentially so: this repository's own `RunOutputFilterTests` contains that literal, so a failure in this suite would misreport itself. See `Fixtures/RunOutput/swift-test-quoted-tally.txt`, which is that run.
    private mutating func recordSummary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let undecorated = Self.undecorated(trimmed)
        // Not under `swift test`'s contract, which owes no `** … **` banner: one there is a test process
        // printing it — this repository's own suite runs fake `xcodebuild`s that do — and keeping it put a
        // `** TEST SUCCEEDED **` among a `swift test` answer's summary lines as though the run had said it.
        if contract != .runTally, trimmed.hasPrefix("** "), trimmed.hasSuffix(" **") {
            buildSummary = trimmed
            return true
        }
        if trimmed.hasPrefix("Build complete!") {
            buildSummary = trimmed
            return true
        }
        // SwiftPM's closing line for a build that failed, read as the build's own verdict rather than dropped as
        // an error that restates the others — only under `swift build`'s contract, the one command that owes
        // `Build complete!`: `swift test`'s closing line is the run tally, and a contract that could not be read
        // takes no literal as a verdict. The first of the two literals is the one kept where both close the log.
        if contract.line(for: .succeeded) == "Build complete!", RunVerdict.buildFailureLines.contains(trimmed) {
            if buildSummary.map(RunVerdict.buildFailureLines.contains) != true {
                buildSummary = trimmed
            }
            return true
        }
        if Self.xctestProcessOpenings.contains(where: { trimmed.hasPrefix($0) }) {
            // Deliberately not consumed: the line is dropped further down like any other counter, and
            // all this records is that a process opened here — so the counter the next one closes on is
            // its own, and so the answer can say how many processes were owed a closing count.
            xctestBundleIsNew = true
            xctestProcessOpenings += 1
            testCrash.openProcess()
            return false
        }
        if Self.xctestOuterSuiteEndings.contains(where: { trimmed.hasPrefix($0) }) {
            // Counted and left to the readers below, as the opening is.
            xctestOuterSuiteEndings += 1
            return false
        }
        if undecorated.hasPrefix("Test run started.") {
            // Dropped the same way as the XCTest opening above, and for the same reason: this is the
            // `swiftpm-testing-helper` process announcing itself, not a counter, so it is not kept as a
            // summary line — only counted, so a closing count this process never prints is still missed.
            swiftTestingProcessOpenings += 1
            testCrash.openProcess()
            return false
        }
        if trimmed.hasPrefix("Executed "), trimmed.contains(" with ") {
            // Counted whether or not it is kept below: a counter this process prints, vestigial or not,
            // is this process closing — see `xctestProcessClosings` for why that is a different question
            // from whether the counter is worth showing.
            if xctestBundleIsNew {
                xctestProcessClosings += 1
            }
            if isVestigialCounter(trimmed) {
                xctestBundleIsNew = false
            } else {
                recordExecutedCounter(trimmed)
            }
            // And read as evidence as well as kept as a line: a counter naming failures is XCTest saying
            // its half of the run went badly, which is the half Swift Testing's closing sentence says
            // nothing about.
            if let counts = ExecutedCounts(line: trimmed), counts.failures > 0 {
                xctestFailed = true
            }
            return true
        }
        if undecorated.hasPrefix("Test run with "), line.first?.isWhitespace == false {
            // Anchored on the first word of the sentence, once the decoration in front of it is gone, and on
            // the start of the line: the library prints its tally at column 0 behind its symbol, so an
            // indented one is a test's own output (a test that echoes a nested run's answer), never this run's.
            // Appended rather than assigned: one tally per test process, and one process per test bundle.
            swiftTestingSummaries.append(String(undecorated))
            return true
        }
        return false
    }

    /// The lines an XCTest process ends its outermost suite on, one per opening in ``xctestProcessOpenings``.
    private static let xctestOuterSuiteEndings = ["All tests", "Selected tests"].flatMap { suite in
        ["passed", "failed"].map { "Test Suite '\(suite)' \($0) at" }
    }

    /// The lines XCTest opens each test process with, which are what separate one bundle's counters from the next's.
    ///
    /// Both, because the outermost suite is named for what was asked: `'All tests'` for a whole run, `'Selected tests'` under `swift test --filter` or `-only-testing:`. Reading only the first left every filtered process unopened — its counters merged into the previous bundle's last-wins, and a filtered `XCTestCase`-only run owed no closing count, so it could never be heard from in full.
    private static let xctestProcessOpenings = [
        "Test Suite 'All tests' started at",
        "Test Suite 'Selected tests' started at",
    ]

    /// Files an `Executed …` total, replacing the one this process has already stated or opening a new one.
    ///
    /// Last-wins within a process — the counter is printed once per suite, once per bundle and once for the run, and only the last speaks for the process — and appended across processes, because a bundle's total is not a restatement of the previous bundle's.
    private mutating func recordExecutedCounter(_ line: String) {
        if xctestBundleIsNew || xctestSummaries.isEmpty {
            xctestSummaries.append(line)
            xctestBundleIsNew = false
            return
        }
        xctestSummaries[xctestSummaries.count - 1] = line
    }

    /// The XCTest counter that speaks for this run, when exactly one process printed one.
    ///
    /// `nil` where several did, for the reason ``soleTally()`` answers `nil` to several run tallies: there is no honest single value across processes, and the lines are all in the answer for the reader to reconcile against. It is read for one thing only — the line a failed verdict quotes — and where two bundles disagree the verdict quotes neither rather than one of them.
    private func soleExecutedCounter() -> String? {
        xctestSummaries.count == 1 ? xctestSummaries.first : nil
    }

    /// Swift Testing's closing count where the run printed exactly one, and `nil` where it printed several.
    ///
    /// `nil` rather than a sum, because a sum would be a count no tool ever printed — Docs/Design.md §3 rule 6, which is also why the tallies themselves are reproduced verbatim above. Summing is worse than it looks: `passed` is a judgement rather than a count, so a total would have to decide what "the run passed" means across bundles, and the answer would then carry an invented number under the same word as `RunTestTally`'s one honest piece of arithmetic. Where there are several, the lines are all in the answer, and ``multiBundleTallyVerdict()`` reconciles them into the package's own pass/fail without ever adding them into one.
    private func soleTally() -> RunTestTally? {
        guard swiftTestingSummaries.count == 1 else {
            return nil
        }
        return swiftTestingSummaries.first.flatMap(RunTestTally.parse)
    }

    /// Whether an `Executed …` line is `xcodebuild` boilerplate rather than a run's own count.
    ///
    /// `Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds` is printed once per run whether or not a single `XCTestCase` exists — every one of the four verdict-reader captures carries it, and a package that has moved wholly to Swift Testing carries nothing else. Keeping it is not a cosmetic wrong: on a log cut off mid-suite it is the only line left in the answer, so a run that never finished would be reported as `✔ xcodebuild` over one cheerful count of nothing.
    ///
    /// All three counts have to be zero, and the shape has to be the one `XCTest` prints. A line this does not recognise is left to the last-wins rule above rather than judged, because a real count wrongly dropped is the same silence from the other direction.
    private func isVestigialCounter(_ line: String) -> Bool {
        guard let counts = ExecutedCounts(line: line) else {
            return false
        }
        return counts.countsNothing
    }
}

extension RunOutputFilter {
    /// The three numbers an XCTest `Executed …` line carries.
    ///
    /// A prefix match, because the tail differs between the two tools that print this line — `in 0.044 seconds` from `swift test` and `in 0.312 (0.314) seconds` from `xcodebuild` — while the counts in front of it are spelled the same way by both.
    struct ExecutedCounts {
        let tests: Int
        /// Tests counted in ``tests`` that threw `XCTSkip`, which XCTest names in a clause of its own only when there are any: `Executed 1 test, with 1 test skipped and 0 failures (0 unexpected)`.
        let skipped: Int
        let failures: Int
        let unexpected: Int

        /// `nil` when the line is not one XCTest wrote.
        init?(line: String) {
            guard let match = line.prefixMatch(
                of: /Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)/
            ),
                let tests = Int(match.1), let failures = Int(match.3), let unexpected = Int(match.4)
            else {
                return nil
            }
            self.tests = tests
            skipped = match.2.flatMap { Int($0) } ?? 0
            self.failures = failures
            self.unexpected = unexpected
        }

        /// Whether the line reports a run of nothing, which is what makes it `xcodebuild` boilerplate rather than a count.
        var countsNothing: Bool {
            tests == 0 && failures == 0 && unexpected == 0
        }
    }
}

// MARK: - The verdict

extension RunOutputFilter {
    /// How the run ended, or `nil` when the log says nothing about it — which is an answer in itself, and is stated out loud rather than passed over.
    ///
    /// The order is decided by the contract rather than by what the log happens to contain. A command that owes a closing line is judged on that line; `swift test`, which owes none, is judged on its run tally — and only on that, because it *builds* before it runs and so prints `Build complete!` on its way past, which is the build's verdict and not the run's. Reading that as the run's is how a suite that failed after a clean build reads as a pass.
    ///
    /// A contract that could not be read answers nothing at all. That is the only safe reading of an `xcodebuild` whose action this tool cannot name: with nothing owed there is nothing to check a literal against, so accepting the literal is scanning for whichever one turned up. The answer says which silence this is — the log carried no verdict, or this tool refused to read the one it carried — because they are different sentences and only the first is about the log.
    ///
    /// **An `xcodebuild -quiet` run that printed no verdict at all can still be read as a pass, from `exitCode` alone — and no other command can.** `-quiet` suppresses every action's own `** … SUCCEEDED **` stamp on a clean run — a `build -quiet` or `test -quiet` that succeeds prints nothing this reader recognises as a verdict, however many warnings sat beside it. `exitCode` here is never guessed: it is the wrapped child's own, read by this process rather than relayed through anything that could mask it (the same trust ``RunLauncher`` already puts in it to report it "passed through exactly"), so where it is `0` and the log carries nothing this filter reads as a failure — no error, no failing test, no XCTest counter reporting one — the silence is read as success instead of left as none. It is marked ``RunVerdict/inferredFromExitCode`` rather than handed a quoted line, so the answer can say plainly that it rests on the exit code of a `-quiet` run and not on a line the tool printed (Docs/AnswerContract.md §8).
    ///
    /// **What that reading cannot see is said rather than hidden.** A `-quiet` run cut short that still exited 0 prints the same silence as one that passed, so it reads the same, and the answer says so. Without `-quiet` there is nothing to infer from: `xcodebuild` prints its banner whenever it finishes and `swift build` prints `Build complete!`, so their silence is a log that stopped early and stays unverdicted whatever the exit code — a truncated capture arrives with exit 0, and reading that as a pass would file it as a run that named its failures. The reading never overrides a `FAILED` or `INTERRUPTED` line the log actually carries — that still wins above — and it never reaches `swift test`'s own contract: `runTallyVerdict(_:)` above already returns before this is reached, because Design.md holds the run tally as the one signal a `swift test` verdict is read from, not an exit code standing in for a tally the log never printed.
    private func verdict(from tally: RunTestTally?, exitCode: Int32?) -> RunVerdict? {
        switch contract {
        case .runTally:
            return runTallyVerdict(tally, exitCode: exitCode)
        case .unreadable:
            return nil
        case .diagnostics:
            guard let exitCode else {
                return nil
            }
            return RunVerdict(state: exitCode == 0 ? .succeeded : .failed, line: nil, owed: nil)
        case .declares:
            break
        }
        if let line = buildSummary, let state = RunVerdict.state(of: line) {
            return RunVerdict(state: state, line: line, owed: contract.line(for: state))
        }
        if quiet, exitCode == 0, diagnostics.errors.isEmpty, testFailures.isEmpty, !xctestFailed {
            return RunVerdict(state: .succeeded, line: nil, owed: nil, inferredFromExitCode: true)
        }
        // Only where nothing was owed: an `xcodebuild` that owes `** TEST EXECUTE FAILED **` and printed
        // no verdict has not failed in any way a reader can act on, however many errors it also emitted.
        return contract.line(for: .failed) == nil ? failedByItsErrors() : nil
    }

    /// How a run judged on its tests rather than on a closing line ended — read from **both** frameworks, because the tally speaks for only one of them.
    ///
    /// Swift Testing prints its closing sentence whether or not a package holds a single `@Test`, and on a package that holds none it reads `Test run with 0 tests in 0 suites passed after 0.001 seconds.` — passed, always. So a `swift test` judged on that sentence alone would answer `✔ swift test — exit 1` over an `XCTestCase` that had just failed, with the failing assertion listed three lines further down its own answer. A tally is a statement about Swift Testing's half, and the verdict of the run is what the two halves say together: either half failing is the run failing, and nothing but both halves being heard from makes it a pass.
    private func runTallyVerdict(_ tally: RunTestTally?, exitCode: Int32?) -> RunVerdict? {
        // Ahead of every count: a process that died ran short of its selection, so no other bundle's pass speaks for the run.
        if settledTestCrash(exitCode: exitCode) != nil {
            return RunVerdict(state: .failed, line: nil, owed: nil)
        }
        if xctestFailed {
            return RunVerdict(state: .failed, line: soleExecutedCounter(), owed: nil)
        }
        if let tally {
            return RunVerdict(state: tally.passed ? .succeeded : .failed, line: swiftTestingSummaries.first, owed: nil)
        }
        return multiBundleTallyVerdict() ?? xctestOnlyVerdict() ?? failedByItsErrors()
    }

    /// The verdict of a `swift test` whose selection held only `XCTestCase` tests, where XCTest's counters are the only closing counts the run owed.
    ///
    /// SwiftPM starts `swiftpm-testing-helper` only for a selection that could hold a `@Test`, so `swift test --filter LegacyTests` prints no `Test run started.` and no `Test run with …` at all — and before this, every such run answered `⚠ … no verdict in the log` over a log that closes on `Executed 1 test, with 0 failures`. The rule stays the one the tally keeps: nothing but every process being heard from makes a pass. So it is a pass only where no Swift Testing process opened, every XCTest process that opened printed a closing count and ended its outermost suite (``xctestOuterSuiteEndings``), at least one of them counted a test, and the log names no failure and no error. A count that counted only skips is still a pass, as XCTest's own `passed` beside it says; the totals line names the skips.
    private func xctestOnlyVerdict() -> RunVerdict? {
        guard swiftTestingProcessOpenings == 0, swiftTestingSummaries.isEmpty,
              xctestProcessOpenings > 0, xctestProcessClosings == xctestProcessOpenings,
              xctestOuterSuiteEndings == xctestProcessOpenings,
              !xctestSummaries.isEmpty, diagnostics.errors.isEmpty, testFailures.isEmpty
        else {
            return nil
        }
        let counts = xctestSummaries.map { ExecutedCounts(line: $0) }
        guard counts.allSatisfy({ $0 != nil && $0?.failures == 0 && $0?.unexpected == 0 }) else {
            return nil
        }
        return RunVerdict(state: .succeeded, line: soleExecutedCounter(), owed: nil)
    }

    /// How several Swift Testing tallies — one per test process, which is one per bundle a multi-target package builds — resolve to one verdict.
    ///
    /// A package's bundles are judged together rather than left to the reader: every bundle passing is the package passing, and any bundle failing is the package failing, named by quoting *that* bundle's own closing sentence. Never a sum — a total is a count no tool printed, the same restraint ``soleTally()`` keeps for the number, and doubly so for `passed`, which is a per-process judgement rather than a count to add. `nil` when a tally line does not parse (which ``RunTestTally/parse(_:)`` already anchors on the whole sentence), leaving the run to ``failedByItsErrors()`` rather than a guess.
    private func multiBundleTallyVerdict() -> RunVerdict? {
        guard swiftTestingSummaries.count > 1 else {
            return nil
        }
        let tallies = swiftTestingSummaries.map { (line: $0, tally: RunTestTally.parse($0)) }
        if let failing = tallies.first(where: { $0.tally?.passed == false }) {
            return RunVerdict(state: .failed, line: failing.line, owed: nil)
        }
        guard tallies.allSatisfy({ $0.tally != nil }) else {
            return nil
        }
        return RunVerdict(state: .succeeded, line: nil, owed: nil)
    }

    /// The verdict of a command that names no failure literal: it has failed when it printed errors — for `swift build` the absence of `Build complete!` *is* the announcement — and has said nothing at all when it did not.
    private func failedByItsErrors() -> RunVerdict? {
        diagnostics.errors.isEmpty ? nil : RunVerdict(state: .failed, line: nil, owed: nil)
    }
}

// MARK: - Test failures

extension RunOutputFilter {
    private mutating func recordTestOutcome(_ line: String) -> Bool {
        if recordSwiftTestingIssue(line) {
            return true
        }
        if recordXCTestAssertion(line) {
            return true
        }
        return noteFailedTest(line)
    }

    /// Swift Testing: `Test name() recorded an issue at File.swift:10:9: Expectation failed: …`, and the parameterized form that names the arguments the case failed under.
    ///
    /// It reads ` recorded an issue ` rather than ` recorded an issue at ` because of that second form. A parameterized test prints `recorded an issue with 1 argument title → "Drum" at File.swift:11:9: …`, and matching only the first form would send every argument-carrying failure — 247 of the 666 issues in the failing capture, across 24 functions — down the path that reports a test as having failed with no message of its own, while its message sits in the log two words further along.
    ///
    /// `recorded a known issue at` is a different sentence and is not matched by either: a known issue is not a failure.
    private mutating func recordSwiftTestingIssue(_ line: String) -> Bool {
        guard let marker = line.range(of: " recorded an issue ") else {
            return false
        }
        guard let name = testName(inHead: String(line[line.startIndex ..< marker.lowerBound])) else {
            return false
        }
        let tail = String(line[marker.upperBound...])
        guard let (arguments, located) = splitIssueTail(tail) else {
            guard let head = tail.prefixMatch(of: Self.argumentsHead) else {
                return false
            }
            openIssue = OpenIssue(name: name, arguments: String(tail[head.range.upperBound...]))
            return true
        }
        recordIssue(name: name, arguments: arguments, located: located)
        return true
    }

    private mutating func recordIssue(name: String, arguments: String?, located: String) {
        let (location, message) = splitLocation(located)
        append(RunTestFailure(name: name, arguments: arguments, location: location, message: message))
        unnotedFailure = testFailures.count - 1
    }

    /// Carries a parameterized failure's arguments on across the line breaks inside a printed value, until the ` at File.swift:10:9:` that ends them arrives.
    ///
    /// Swift Testing prints an argument's value as it is, so `@Test(arguments: ["a\nb"])` fails as `recorded an issue with 1 argument leaf → "a` and, on the next line, `b" at File.swift:6:5: …`. Read one line at a time, the first half names no location and the second no test, and the failure was dropped from the listing while the run's own tally still counted it. The break is kept as an escaped `\n`, the way the source spelled it, because a failure is rendered on one line.
    ///
    /// Holding stops at a line that opens an event of its own (``opensAnEvent(_:)``) or at ``openIssueLineCap``, and the failure is then listed with its arguments so far and no location, rather than lost. Only the line just read is searched for the location, since the lines before it were searched as they arrived — so a long value costs one pass over it, not one per line.
    private mutating func continueOpenIssue(_ line: String) -> Bool {
        guard var open = openIssue else {
            return false
        }
        openIssue = nil
        guard open.lines < Self.openIssueLineCap, !Self.opensAnEvent(line) else {
            appendUnlocated(open)
            return false
        }
        open.lines += 1
        let text = Substring(line)
        guard let boundary = locationBoundary(in: text) else {
            open.arguments += #"\n"# + line
            openIssue = open
            return true
        }
        let arguments = open.arguments + #"\n"# + text[..<boundary.lowerBound]
        recordIssue(name: open.name, arguments: arguments, located: String(text[boundary.upperBound...]))
        return true
    }

    /// Whether `line` is an event of the run's own rather than a line of a value Swift Testing is printing.
    ///
    /// Swift Testing opens every event on a glyph — `◇`, `✘` or an SF Symbol, its colour escapes already stripped in ``consume(line:)`` — and XCTest and `xcodebuild` open theirs on `Test Case '…'` or `Test Suite '…'`, either case. A value is printed as it is, bare, so an argument whose second line reads `Test y` prints that line bare, and it is the argument's, not an event: reading the first word alone cut such a failure off from the location on the line after it.
    static func opensAnEvent(_ line: String) -> Bool {
        if ["Test Case '", "Test Suite '", "Test case '", "Test suite '"].contains(where: { line.hasPrefix($0) }) {
            return true
        }
        guard let first = line.unicodeScalars.first, !first.isASCII else {
            return false
        }
        let undecorated = Self.undecorated(line)
        return undecorated.hasPrefix("Test ") || undecorated.hasPrefix("Suite ")
    }

    private mutating func appendUnlocated(_ open: OpenIssue) {
        append(RunTestFailure(
            name: open.name,
            arguments: open.arguments,
            location: nil,
            message: "its arguments ran on across \(open.lines) lines with no location after them — see the raw log"
        ))
    }

    /// Folds a `↳` comment into the failure printed directly above it.
    ///
    /// That comment is the human sentence on the expectation — `↳ 'Cogs' is missing from the binlabel sign` — and without a place for it in the answer, 641 of them would be dropped from the failing capture while the failures they explain are kept.
    ///
    /// **Attribution is by adjacency and by nothing else, and that is an approximation, not a fact.** The marker heads lines that belong to no failure at all (`↳ Testing Library Version: 1902`), which is why the claim has to expire; and `xcodebuild` interleaves the output of parallel test runners, so a `↳` can arrive under a *neighbouring* test's failure and be folded into it. Nothing in the log says which issue a continuation belongs to, so there is no better reading available; what there is instead is this sentence, since an approximation nobody states is the one that gets read as a fact.
    ///
    /// **What the interleaving does to a line is handled rather than described.** Every splice the corpus holds — three in the passing capture, one in the truncated — is ``RunOutputFilter/outputBarrier`` in front of an otherwise intact line, and it comes off in ``consume(line:)`` before any reader here sees it. A `recorded an issue` line that arrives spliced is therefore read like any other: name, location, message and the note beneath it. `aBarrierSplicedOntoAnIssueLineIsStrippedBeforeTheLineIsRead` is that claim. What is left over is the paragraph above, which is about which failure a continuation belongs to rather than about the characters a line begins with.
    ///
    /// A note that runs to more than one line stays whole. Consecutive `↳` lines are one note: the claim is renewed here rather than expiring on the line that consumed it, which would leave a two-line note as its first line alone — in the failing capture, the source comment kept and the sentence that said what actually went wrong dropped.
    private mutating func recordMarkedNote(_ line: String, on index: Int?) -> Bool {
        guard let index, let note = markedContinuation(in: line) else {
            return false
        }
        foldNoteLine(note, marked: true, into: index)
        return true
    }

    /// Folds a line Swift Testing indented beneath a `↳` into the note still open above it, before ``recordSummary(_:)`` or ``recordTestOutcome(_:)`` can read it as the run's own line.
    ///
    /// **A line inside a failure's note is the test's text, never the run's, whatever it says.** Swift Testing prints a multi-line `#expect` comment as a `↳` line and then indented lines, one per line of the comment, so a test that quotes a log puts that log's sentences at the start of indented lines inside its own note. Undecorated, `Test run with 2 tests in 0 suites failed after 0.001 seconds with 3 issues.` reads exactly like the run's closing sentence, `Executed 3 tests, with 2 failures (0 unexpected) in 0.100 (0.100) seconds` like XCTest's counter, and `Test ghost() failed after 0.001 seconds with 1 issue.` like a test's ending. Read as the run's, the first two put a stray tally in the summary and in `totals:`, and the third a test that never ran into the outcomes and a failure into the listing.
    ///
    /// **A real summary or outcome line is never one of these, on two grounds.** A note opens only on a Swift Testing issue (``recordIssue(name:arguments:located:)``) and ends at the first line that is neither a continuation nor a held blank. Swift Testing's own lines open on a status glyph, never on whitespace, so its tally and every test's ending close the note rather than join it. XCTest's counter is indented, but XCTest prints it only directly beneath its `Test Suite '…' passed|failed at …` line, which closes the note first — in every capture in `Fixtures/RunOutput/`, the next bundle's process after a noted failure under `xcodebuild` included. And it is indented by a tab (`\t Executed …`), where Swift Testing opens every later line of a comment on two spaces (``quotedContinuation(in:)``), so a counter arriving under an open note all the same still reaches ``recordSummary(_:)``. See `Fixtures/RunOutput/swift-test-noted-tally.txt` and `Fixtures/RunOutput/*-noted-shapes.txt`.
    private mutating func recordQuotedLine(_ line: String, on index: Int?) -> Bool {
        guard index != nil, quotedContinuation(in: line) != nil else {
            return false
        }
        return recordPlainContinuation(line, on: index)
    }

    /// A continuation with no `↳` of its own — reached for a line ``recordQuotedLine(_:on:)`` did not take only once ``recordSummary(_:)`` and ``recordTestOutcome(_:)`` have both already turned it away, so a tab-indented `Executed …` counter is never misread as a failure's note.
    private mutating func recordPlainContinuation(_ line: String, on index: Int?) -> Bool {
        guard let index, let note = plainContinuation(in: line) else {
            return false
        }
        foldNoteLine(note, marked: false, into: index)
        return true
    }

    /// Folds one continuation line into `index`'s note while ``noteContinuationCap`` allows it, and counts it instead once it does not.
    ///
    /// An empty `note` is a held blank the note went on across: part of the haystack a containment failure searches, and nothing in the note a reader sees, which joins its lines with a space.
    private mutating func foldNoteLine(_ note: String, marked: Bool, into index: Int) {
        bufferContainmentLine(RunFailureCensus.NoteLine(text: note, marked: marked), of: index)
        unnotedFailure = index
        guard !note.isEmpty else {
            return
        }
        let kept = noteLinesKept[index, default: 0]
        if kept < Self.noteContinuationCap {
            testFailures[index] = testFailures[index].noting(note, apart: !marked)
            noteLinesKept[index] = kept + 1
        } else {
            noteLinesElided[index, default: 0] += 1
        }
    }

    /// Keeps one note line of a containment failure for the search ``closeNote(for:)`` runs, until ``RunFailureCensus/closestLineNoteLimit`` is reached and the rest is only marked as cut.
    private mutating func bufferContainmentLine(_ line: RunFailureCensus.NoteLine, of index: Int) {
        if containmentNote?.index != index {
            guard RunFailureCensus.namesContainment(testFailures[index].message) else {
                return
            }
            containmentNote = ContainmentNote(index: index)
        }
        guard var note = containmentNote, !note.truncated else {
            return
        }
        let limit = RunFailureCensus.closestLineNoteLimit
        if note.lines.count >= limit.lines || note.bytes + line.text.utf8.count > limit.bytes {
            note.truncated = true
        } else {
            note.lines.append(line)
            note.bytes += line.text.utf8.count
        }
        containmentNote = note
    }

    /// Closes `index`'s note once the chain of continuation lines feeding it ends: names the haystack line a containment failure's whole note points at, then counts what the cap left out.
    private mutating func closeNote(for index: Int) {
        if let note = containmentNote, note.index == index {
            containmentNote = nil
            if let closest = RunFailureCensus.closestLine(message: testFailures[index].message, note: note.lines, truncated: note.truncated) {
                testFailures[index] = testFailures[index].withClosestLine(closest)
            }
        }
        finalizeElidedNoteLines(for: index)
    }

    /// Folds however many continuation lines a failure carried past ``noteContinuationCap`` into one elision on its note, once the chain that was counting them ends.
    ///
    /// Matches the wording ``RunFailureCensus/clipped(_:)`` already ends a bounded message on — a count of what was left behind rather than a bare ellipsis — so a reader sees one shape for "there was more" wherever this answer states it.
    private mutating func finalizeElidedNoteLines(for index: Int) {
        guard let elided = noteLinesElided[index], elided > 0 else {
            return
        }
        testFailures[index] = testFailures[index].noting("… (+\(elided) more lines — see the raw log)", apart: true)
        noteLinesElided[index] = 0
    }

    /// XCTest: `File.swift:10: error: -[Suite testName] : XCTAssertEqual failed: …`.
    private mutating func recordXCTestAssertion(_ line: String) -> Bool {
        guard let diagnostic = RunDiagnostic.parse(line), diagnostic.severity == .error else {
            return false
        }
        guard diagnostic.isXCTestAssertion, let split = diagnostic.message.range(of: "] : ") else {
            return false
        }
        let location = diagnostic.path.map { path in
            diagnostic.line.map { "\(path):\($0)" } ?? path
        }
        xctestFailed = true
        append(RunTestFailure(
            name: String(diagnostic.message[diagnostic.message.startIndex ..< split.lowerBound]) + "]",
            location: location,
            message: String(diagnostic.message[split.upperBound...])
        ))
        return true
    }

    /// A test the framework declared failed, remembered so a failure carrying no message of its own is still reported.
    ///
    /// **It does not exclude the run tally, because it cannot see one.** `Test run with 2 tests in 1 suite failed after 0.001 seconds with 2 issues.` carries ` failed after `, so a reader that could see it would have to turn it away by hand — which only a ``recordSummary(_:)`` searching the whole line, a reading that can miss, would call for. Anchored, it cannot miss: this reader's head and that one's line undecorate to the same first word, so a head reading `Test run with …` means the line did too and ``recordSummary(_:)`` consumed it three calls earlier. A guard here would be defending against a state that never reaches here.
    private mutating func noteFailedTest(_ line: String) -> Bool {
        if line.hasPrefix("Test Case '"), let close = line.range(of: "' failed") {
            let start = line.index(line.startIndex, offsetBy: "Test Case '".count)
            failedTestNames.insert(String(line[start ..< close.lowerBound]))
            // `Test Case '…' failed` is XCTest's wording, so it is also XCTest's half of the run
            // declaring itself — the half a Swift Testing run tally has nothing to say about.
            xctestFailed = true
            return true
        }
        // Read by the name's own shape, as the outcomes are, never by searching for the marker: a case's
        // `Test case passing 1 argument event → "✘ Test boils() failed after …" to f(event:) started.` holds
        // ` failed after ` inside its argument, and everything in front of it was filed as a failed test
        // called `case passing 1 argument event → "✘ Test boils()`.
        guard let (name, event) = RunTestOutcomes.swiftTestingEvent(in: line), case .failed = event else {
            return false
        }
        failedTestNames.insert(name)
        return true
    }

    /// A failure the framework announced but never explained is still a failure; saying so beats letting it vanish.
    private mutating func appendUnexplainedFailures() {
        for name in failedTestNames.sorted() where !reportedTestNames.contains(name) {
            testFailures.append(RunTestFailure(
                name: name,
                location: nil,
                message: "failed with no message of its own — see the raw log"
            ))
        }
    }

    private mutating func append(_ failure: RunTestFailure) {
        testFailures.append(failure)
        reportedTestNames.insert(failure.name)
    }

    /// The test's name from the part of the line before the marker, or `nil` when the line names a suite rather than a test.
    ///
    /// **The word `Test` is read where the framework writes it — first, immediately after the decoration — and never searched for backwards.** A backwards search takes the *last* ` Test ` in the head, which is the author's word rather than Swift Testing's the moment a display name contains one: `Suite "Reflow Test Grid" failed after …` would be read as a test called `Grid"`, get a failure invented for it in ``appendUnexplainedFailures()`` against a run whose own tally said two issues, and have that name filed into `run.jsonl` and from there into `flakes` — a test that does not exist, recorded as having failed. `Test "The Test Reads Its Own Name" recorded an issue …` is the milder half of the same fault, and would report as `Reads Its Own Name"`.
    ///
    /// A backwards search is what surviving `xcodebuild` splicing one runner's line through the middle of another's would call for, and the captured red run does not support it: `Test .* Test ` occurs zero times in 8,185 lines. What splicing actually looks like there is ``RunOutputFilter/outputBarrier`` on the head of a line, which ``consume(line:)`` takes off before this is reached — so that case arrives here already repaired, and the failure a backwards search causes in exchange is ordinary Swift Testing. The display name is what the reading is sized against.
    ///
    /// **Decoration is dropped by category rather than by enumerating glyphs.** Every one of these lines opens with a status glyph and whitespace, and which glyph depends on the terminal Swift Testing thinks it is writing to — `✘` in the `xcodebuild` captures, a private-use SF Symbol under `swift test` — with a zero-width space in front of it on some lines and not others in the same run. None of them is a letter or a digit, and the word that follows always is, so a run of neither is exactly the decoration.
    ///
    /// The suite check lives here with it. A suite line is one whose first word is `Suite`, which is a fact about the head; testing the *name* for it works only while nothing can stand between the two. XCTest's `Test Suite 'X'` is a third shape that reaches this and still has to be turned away, which is what the remaining prefix guards are for.
    private func testName(inHead head: String) -> String? {
        let undecorated = Self.undecorated(head)
        guard undecorated.hasPrefix("Test ") else {
            return nil
        }
        let name = undecorated.dropFirst("Test ".count).trimmingCharacters(in: .whitespaces)
        // `case ` is Swift Testing's own parameterized-case event, `Test case passing 1 argument … started.`,
        // whose argument can quote a whole failure line: never a test's name.
        guard !name.isEmpty, !name.hasPrefix("Case "), !name.hasPrefix("case "), !name.hasPrefix("Suite ") else {
            return nil
        }
        // `Test everyDoorSurvivesEveryTextSize(size:) with 3 test cases failed after …` — the clause sits
        // between the name and the marker, so taking everything in front of the marker as the name would
        // file one function under two names depending on which line reported it. It is a count of the
        // cases the framework ran, not part of what the function is called.
        return name.replacing(#/ with \d+ test cases?$/#, with: "")
    }

    /// Splits what follows `recorded an issue` into the arguments the case carried, if any, and the `File.swift:10:9: …` after them.
    ///
    /// Two shapes, both real: `at File.swift:10:9: …` from a plain test, and `with 1 argument size → .large at File.swift:312:13: …` from a parameterized one. `nil` for anything else, which leaves the line to the readers after this one rather than to a guess.
    ///
    /// The boundary in the second shape is the ` at ` that a `File.swift:10:9:` token follows — not the first in the line and not the last. An argument's printed value can contain the word and so can the message after it, and only the shape of what comes next tells the three apart.
    private func splitIssueTail(_ tail: String) -> (arguments: String?, located: String)? {
        if tail.hasPrefix("at ") {
            return (nil, String(tail.dropFirst(3)))
        }
        guard let head = tail.prefixMatch(of: Self.argumentsHead) else {
            return nil
        }
        let arguments = tail[head.range.upperBound...]
        guard let boundary = locationBoundary(in: arguments) else {
            return nil
        }
        return (String(arguments[..<boundary.lowerBound]), String(arguments[boundary.upperBound...]))
    }

    /// The ` at ` that separates a failure's arguments from where it failed.
    private func locationBoundary(in text: Substring) -> Range<Substring.Index>? {
        var searchFrom = text.startIndex
        while let candidate = text.range(of: " at ", range: searchFrom ..< text.endIndex) {
            // Bounded by the first whitespace, so a message with no location in it costs one token's
            // worth of looking per candidate rather than a scan to the end of a kilobyte-long line.
            let token = text[candidate.upperBound...].prefix { !$0.isWhitespace }
            if token.wholeMatch(of: /\S+:\d+:\d+:/) != nil {
                return candidate
            }
            searchFrom = candidate.upperBound
        }
        return nil
    }

    /// Splits `File.swift:10:9: Expectation failed: …` into its location and its message.
    private func splitLocation(_ tail: String) -> (String?, String) {
        guard let separator = tail.range(of: ": ") else {
            return (nil, tail)
        }
        return (String(tail[tail.startIndex ..< separator.lowerBound]), String(tail[separator.upperBound...]))
    }

    /// The text of a `↳` continuation line, or `nil` when the line is not one.
    ///
    /// The marker is searched for rather than anchored on the start of the line: 306 lines of the captured logs carry a zero-width space (U+200B) in front of their glyph, and `CharacterSet.whitespaces` does not contain it, so a prefix test on the raw line is exactly the reader that misses them.
    private func markedContinuation(in line: String) -> String? {
        guard let marker = line.firstIndex(of: "↳") else {
            return nil
        }
        guard line[line.startIndex ..< marker].allSatisfy({ $0.isWhitespace || $0 == "\u{200B}" }) else {
            return nil
        }
        let note = line[line.index(after: marker)...].trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? nil : note
    }

    /// The text of a continuation line that carries no `↳` of its own, or `nil` when the line is not indented at all.
    ///
    /// **A merely-indented line is a continuation too, on the same terms as an error's colon-continuation (``appendColonContinuation(_:)``).** A `↳` comment can itself end on a colon and open a list the next, unmarked, indented line answers: `Expectation failed: wrong.isEmpty` / `↳ 1 citation(s) name a line their rule is not on: (by adjacency)` / an indented line naming the actual citation is three lines, and a reader who sees only the first two is missing the sentence the comment was written to introduce. Consulted only while a failure's note is open, which a real summary or outcome line never arrives inside (see ``recordQuotedLine(_:on:)``), so an indented one — XCTest's `\t Executed …` counter — is never mistaken for one of these.
    ///
    /// **Genuine whitespace only — never the zero-width space (U+200B) some of Swift Testing's own decorated lines open on.** ``markedContinuation(in:)`` skips past a leading U+200B because it is looking for the `↳` glyph behind it, but a status line like `◇ Suite BinLabelTests started.` can carry the same leading U+200B in front of its own glyph and nothing that follows is a continuation of anything — reading `isWhitespace` alone (which U+200B is not) is what keeps a decorated status line, of all things, from being folded into the failure printed above it.
    private func plainContinuation(in line: String) -> String? {
        guard let first = line.first, first.isWhitespace else {
            return nil
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The text of a continuation in the shape Swift Testing prints a comment's later lines in — opening on a space — or `nil` for any other line, a tab-indented one included.
    ///
    /// Swift Testing puts two spaces in front of every line of a multi-line comment after the first, whatever the line itself opens on, so a quoted `Executed …` counter arrives as `    Executed …`. XCTest's own counter opens on a tab.
    private func quotedContinuation(in line: String) -> String? {
        line.first == " " ? plainContinuation(in: line) : nil
    }

    /// Whether `line` is the indented nothing Swift Testing prints for an empty line inside a note — whitespace, and some of it; a line with nothing at all on it is left to end the note, as it always has.
    private static func isBlank(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy(\.isWhitespace)
    }

    /// The `with 1 argument ` that opens a parameterized failure's arguments.
    private static var argumentsHead: Regex<Substring> {
        #/with \d+ arguments? /#
    }

    /// A parameterized failure's name and its arguments so far, while ``continueOpenIssue(_:)`` waits for the line naming its location.
    private struct OpenIssue {
        let name: String
        var arguments: String
        var lines = 1
    }

    /// The note lines of one containment failure kept for its closest-line search, how many bytes they hold, and whether ``RunFailureCensus/closestLineNoteLimit`` left the rest unread.
    private struct ContainmentNote {
        let index: Int
        var lines: [RunFailureCensus.NoteLine] = []
        var bytes = 0
        var truncated = false
    }
}
