//
// Copyright © Agulhas Labs
//

import Foundation

/// Turns a `RunReport` into the answer a caller reads instead of the build log.
///
/// Every number it prints is either the tool's own or reconciles against something listed directly beneath it, and the tail always names the raw log — the compression is lossy, so the receipt is the part that makes it safe.
public struct RunReportRenderer: Sendable {
    private let kind: RunCommandKind
    private let paths: RunAnswerPaths
    private let changedFiles: RunChangedFiles
    private let sites: RunFailureSites
    private let accessibility: [SimulatorAccessibility.Restoration]
    private let testBundles: RunTestBundles
    private let selector: RunTestSelector?
    /// What ``RunInventoryCheck`` said about the run, printed under the totals line; empty where the run was not one it checks.
    private let inventory: [String]

    /// - Parameter workingDirectory: Where this answer is being read, which is the only thing the paths in it are stated relative to — and, since that is a fact about the reader rather than about the run, nothing this answer *measures*. See ``RunAnswerPaths``.
    /// - Parameter changedFiles: What the working tree has changed, for the classification's "is this mine?" field. Taken as a value rather than discovered here so this type stays pure — the caller has already paid a `git` process to find the repository root and is the right place to pay for one more. The default states that nobody asked, which is the honest reading and never a zero.
    /// - Parameter sites: The declarations the failure locations resolved to, taken as a value for the same reason and defaulting to nothing resolved — which renders the answer with no resolved lines at all.
    /// - Parameter accessibility: What re-arming the accessibility preference did, one entry per simulator the run named, in argv order — taken as a value for the same reason, since the spawns it costs are the caller's to pay. Empty is a run that put no test on a simulator, and prints no line about one.
    /// - Parameter selector: The tests the command named to run, read from argv by the caller for the same reason as `testBundles`. A run that exited 0 having executed none of them answers `✘` rather than whatever its log declared. `nil` names none, and judges nothing.
    /// - Parameter testBundles: How many test bundles the run was owed a count from, which is the one fact about it that is not in its own log — taken as a value for the same reason, since reading it costs a manifest parse the caller decides whether to pay. The default states that nobody asked, and prints nothing about a bundle that never reported.
    public init(
        kind: RunCommandKind,
        workingDirectory: URL,
        changedFiles: RunChangedFiles = .unavailable("the working tree was not consulted"),
        sites: RunFailureSites = .none,
        accessibility: [SimulatorAccessibility.Restoration] = [],
        testBundles: RunTestBundles = .undetermined,
        selector: RunTestSelector? = nil,
        inventory: [String] = []
    ) {
        self.inventory = inventory
        self.kind = kind
        paths = .read(in: workingDirectory)
        self.changedFiles = changedFiles
        self.sites = sites
        self.accessibility = accessibility
        self.testBundles = testBundles
        self.selector = selector
    }
}

extension RunReportRenderer {
    public func render(_ report: RunReport, exitCode: Int32, logURL: URL?) -> String {
        var lines: [String] = [headline(report, exitCode: exitCode)]
        // Only beside the headline that names the crash, which a run that exited 0 never carries.
        if exitCode != 0 {
            lines.append(contentsOf: report.compilerCrash?.lines() ?? [])
            lines.append(contentsOf: report.testCrash?.lines() ?? [])
        }
        // The note is owed by what this answer will actually print, not by what the report happened to
        // hold — see ``summaries(of:)`` for the pair that can come apart on that difference.
        let summaries = summaries(of: report)
        let totals = totalsLine(report, exitCode: exitCode)
        lines.append(contentsOf: shown(summaries, of: report, beside: totals).map { "  \($0)" })
        // A pass read off the exit code has no line of the tool's to point at, and sending the reader to the
        // raw log would ask them to find the verdict this answer already says is not there. What it owes them
        // instead is what the pass rests on, and the one case that reading cannot tell apart from it.
        if report.verdict?.inferredFromExitCode == true {
            lines.append("  -quiet prints no closing line on a pass, so this rests on the exit code alone: a -quiet run cut short that still exited 0 would read the same")
        } else if summaries.isEmpty, report.contract != .diagnostics, report.testCrash == nil {
            // Withheld for a contract that owes no closing line: a linter states its result in the exit
            // code, so a reader sent to the raw log for a summary would be sent to look for something
            // neither the tool nor this answer ever claimed was there.
            // Sending the reader to the raw log says the answer is incomplete, which it is not where it
            // already lists the errors that failed the run: name what the log lacked instead.
            lines.append(report.errors.isEmpty ? "  summary not found — see the raw log" : "  no closing summary line in the log — the errors below are what it reported")
        }
        if let owed = report.verdict?.owed, report.verdict?.answersTheInvokedCommand == false {
            lines.append("  the action this command invoked ends on \(owed), which the log never reached")
        }
        lines.append(contentsOf: knownIssueArithmetic(report))
        let warnings = warningSection(report)
        // What the log has left after everything else this answer prints is what the two listings may
        // spend between them — see ``allowance(of:beside:)`` for why an answer owes the log that. The
        // totals line is composed already, same as the summaries and warnings above it, so it is charged
        // here rather than appended for free below — an answer that overspends its allowance by exactly
        // the one line this closes on is the bug ``allowance(of:beside:)`` exists to prevent. The size
        // budget is shared on exactly the same terms: one answer, one budget, spent in the order the
        // sections print, because the receipt below them states one number for the whole of it.
        let devices = deviceNotes(of: report)
        let streamNote = report.eventStreamNote.map { ["  \($0)"] } ?? []
        var allowance = allowance(of: report, beside: lines.count + warnings.count + (totals == nil ? 0 : 1) + streamNote.count + inventory.count, notes: devices.lines.count)
        var budget = RunFailureCensus.listingBudget
        let errors = errorSection(report, within: allowance, spending: &budget)
        allowance = max(0, allowance - errors.count)
        let failures = testFailureSection(report, leadingWith: devices.leadFailures ? devices.lines : [], within: allowance, spending: &budget)
        lines.append(contentsOf: errors)
        lines.append(contentsOf: failures)
        lines.append(contentsOf: warnings)
        if let totals {
            lines.append(totals.line)
        }
        lines.append(contentsOf: streamNote)
        lines.append(contentsOf: inventory)
        // The receipt counts itself along with everything above it: the line being appended is the last. That is the whole of the arithmetic — the answer is the
        // only thing that knows its own size, and asking it here is what keeps the receipt from being a
        // second opinion about what was printed.
        //
        // The accessibility notes sit *under* the receipt — they are facts about the devices rather than about
        // the log the tail names — unless the failures read empty trees, where they lead the failures instead.
        // Under the receipt they are counted into its own number before they are appended, since a line of the
        // answer the answer's size does not count is a receipt that understates itself. One per device that
        // owes one, in the order argv named them.
        let trailing = devices.leadFailures ? [] : devices.lines
        lines.append(receipt(report, answerLines: lines.count + 1 + trailing.count, logURL: logURL))
        lines.append(contentsOf: trailing)
        // Last, over every line whichever section composed it: no line of an answer is ever the size of a line
        // a log can carry. See ``lineCap``.
        return lines.map { RunFailureCensus.clipped($0, to: Self.lineCap) }.joined(separator: "\n")
    }

    /// The most bytes one line of an answer may carry before it is clipped, with the count of what was left in the raw log.
    ///
    /// The size of the whole listing budget (``RunFailureCensus/listingBudget``), so a complete error listing is never clipped — a compile error spelling a long generic type runs to kilobytes — and far below the lines a log can carry: a frontend command is one line holding every source path its job compiled, tens of kilobytes, and one of those quoted whole is thousands of tokens of nothing a reader acts on.
    public static let lineCap = RunFailureCensus.listingBudget

    /// The tool's own summary lines, less any that declares a state this run's verdict contradicts.
    ///
    /// One line is dropped by that rule in practice, and it is the one `RunOutputFilter.verdict(from:)`'s doc says must never read as the run's verdict: `swift test` *builds* before it runs, so `Build complete! (0.49s)` sits in its output and would otherwise be printed directly under `✘ swift test — exit 1` — the build's verdict, restated as this run's, one line below a headline saying the opposite. Filtering it here rather than dropping it in the filter keeps Docs/Design.md §3 rule 6 intact: the line is a real summary the tool printed, it stays in the report, and what changes is only whether this answer stands it beside a verdict that disagrees with it.
    ///
    /// A verdict's own line is never dropped by this, which is what leaves `⚠ … the log's verdict is not this command's` showing the offending line it is complaining about. Nor is anything dropped where there is no verdict to contradict — a reader being sent to the raw log should see every summary there was, and that is exactly the case where one of them is the evidence for the headline.
    ///
    /// **This is also what decides whether the answer owes a `summary not found` note**, and the two must be asked of the same collection. Guarding the note on the report's summary lines while the block prints these fails on exactly this case: a `swift test` that failed after building has `summaryLines == ["Build complete! (0.49s)"]` and exactly that one line filtered out here — so the guard would see a non-empty report, the block would print nothing, and the headline would stand alone with neither a summary nor the note saying there was none.
    func summaries(of report: RunReport) -> [String] {
        guard let verdict = report.verdict else {
            return report.summaryLines
        }
        return report.summaryLines.filter { line in
            line == verdict.line || RunVerdict.state(of: line).map { $0 == verdict.state } ?? true
        }
    }

    /// The one line every caller reads, and the one place this answer is allowed to be loud.
    ///
    /// The exit code is restated beside the verdict and never reinterpreted — it stays the caller's contract (`RunOutcome.exitCode`) — because the two are different claims: the number is what the child process returned, and the glyph is what the *log* says happened. Where the log says nothing, or says something this command never owed, the glyph is `⚠` and the headline names which, because a filtered answer that reads as a pass over output nobody could parse is the worst thing this command can produce.
    ///
    /// **Three anomalies, and the third is the one that catches what nobody enumerated.** A log that declares success over a child that exited nonzero is the two claims contradicting each other outright, and there is no reading of that pair worth a tick: `xcodebuild test` prints `** TEST SUCCEEDED **` and exits 65 when a diagnostic came before it, `swift build` prints `Build complete!` and exits 1 for the same reason, and a `swift test` whose Swift Testing half passed while its `XCTestCase` failed can arrive here as a pass too. Each of those has its own fix further up, and each is a case somebody had to enumerate — this test is the structural one, because it does not need to know *why* the two disagree to refuse to print a tick over the disagreement.
    ///
    /// **A missing verdict is two different sentences and gets two different headlines.** One says the log ran out without declaring anything, which is the truncated capture. The other says this tool would not read the verdict the log carries, because it could not tell which line the invoked action owed — and printing the first sentence for it would be false, over a log quoting `** TEST EXECUTE SUCCEEDED **` two lines beneath it. The refusal is right; the claim about the log would not be.
    func headline(_ report: RunReport, exitCode: Int32) -> String {
        let stated = verdictHeadline(report, exitCode: exitCode)
        guard let qualification = SimulatorAccessibility.qualification(of: accessibility) else {
            return stated
        }
        return "\(stated) — \(qualification)"
    }

    /// The headline the log itself earns, before anything about the device it ran on qualifies it.
    private func verdictHeadline(_ report: RunReport, exitCode: Int32) -> String {
        // Before the log's own verdict, which for this run is `** TEST SUCCEEDED **` or none at all: neither
        // is a statement about the tests the command named, since not one of them ran.
        if let selector, selector.matchedNothing(report, exitCode: exitCode) {
            return selector.headline(label: kind.label)
        }
        if let selector, selector.didNotBuild(report, exitCode: exitCode) {
            let crashed = report.compilerCrash == nil ? "" : " — compiler crashed"
            return RunTestSelector.didNotBuildHeadline(label: kind.label, exitCode: exitCode) + crashed
        }
        // Before the verdict too, which is a pass of the other filters' tests and says nothing of this one.
        if let selector, case let unmatched = selector.unmatchedFilters(report, exitCode: exitCode), !unmatched.isEmpty {
            return selector.headline(label: kind.label, unmatched: unmatched)
        }
        if let declared = testBundles.count, RunTestSelector.executedNothing(report, exitCode: exitCode, testBundles: testBundles) {
            return RunTestSelector.executedNothingHeadline(label: kind.label, declared: declared)
        }
        // Ahead of the verdict, which a crashed build rarely prints and never explains: the crash is the reason.
        if report.compilerCrash != nil, exitCode != 0 {
            return "✘ \(kind.label) — exit \(exitCode) — compiler crashed"
        }
        if report.testCrash != nil, exitCode != 0 {
            return "✘ \(kind.label) — exit \(exitCode) — test process crashed"
        }
        guard let verdict = report.verdict else {
            guard report.contract == .unreadable else {
                return "⚠ \(kind.label) — exit \(exitCode), and no verdict in the log; see the raw output"
            }
            return "⚠ \(kind.label) — exit \(exitCode), and this tool could not tell which verdict the command owed, so it read none; see the raw output"
        }
        guard verdict.answersTheInvokedCommand else {
            return "⚠ \(kind.label) — exit \(exitCode), and the log's verdict is not this command's; see the raw output"
        }
        guard verdict.state != .succeeded || exitCode == 0 else {
            return "⚠ \(kind.label) — the log declares success but the command exited \(exitCode); see the raw output"
        }
        if verdict.inferredFromExitCode {
            return "✔ \(kind.label) — no verdict printed under -quiet; read as passed from exit 0, with no errors or test failures logged"
        }
        return stated(verdict.state, exitCode: exitCode)
    }

    /// The headline for a verdict the answer can stand behind.
    ///
    /// Interruption gets a glyph of its own rather than being folded into either neighbour: a run that was killed is not a failure of the code and not a pass, and the interrupted capture is exactly where a two-state reader goes wrong twice — its verdict says `INTERRUPTED` while its own suite line says `failed`.
    private func stated(_ state: RunVerdict.State, exitCode: Int32) -> String {
        let exit = exitCode == 0 ? "" : " — exit \(exitCode)"
        return switch state {
        case .succeeded: "✔ \(kind.label)\(exit)"
        case .failed: "✘ \(kind.label)\(exit)"
        case .interrupted: "◼ \(kind.label) — interrupted, exit \(exitCode)"
        }
    }

    /// The one count in this answer the tool did not print for itself: how many of Swift Testing's issues were failures.
    ///
    /// Stated only when the run recorded a known issue, because otherwise its own issue count *is* the failure count and restating it would be a second number to be wrong about. When it did, the arithmetic is the whole point — `withKnownIssue` is a written-down expectation that something is broken, so a green run carrying one has to keep reading green, and a red one has to be counted without it.
    ///
    /// **Named after the framework it counts, because it counts only that one.** The number here is Swift Testing's issues less its known issues, while the classification line below it counts the failures of *both* frameworks; on the corpus the two agree, which is exactly why a disagreement between them standing one above the other is easy to miss. A run with a Swift Testing known issue and failing `XCTestCase`s prints two different numbers under the same word, and the label is what tells a reader which denominator each is over.
    ///
    /// `report.tally` stays `nil` for a package with more than one test bundle — a summed count is a number no tool printed — so on that shape this instead parses every bundle's own summary line and prints one labelled arithmetic line per bundle that carries a known issue. Each label states that bundle's own `N tests in M suites` *and* its position among every Swift Testing tally line in the run, because two bundles agreeing on both counts — the same fixture run twice, or simply two same-sized bundles — would otherwise print two identical-looking lines with nothing to tell a reader they are not one line repeated. The position is counted over the tally lines — classified the same way `RunOutputFilter.recordSummary` classifies them, on `Test run with ` once the leading decoration is gone — not only the ones that go on to parse, so "2 of 2" always names the printed line it is beside, even when another one of them does not match `RunTestTally.parse`'s pattern. **It is worded `bundle N of M` and not `tally N of M`**: a second line of that shape is a second Swift Testing *run*, which is a second process and so a second bundle, never this run's second framework — and the old wording was read as exactly that claim.
    private func knownIssueArithmetic(_ report: RunReport) -> [String] {
        if let tally = report.tally {
            return arithmeticLine(for: tally, bundle: nil).map { [$0] } ?? []
        }
        let tallyLines = report.summaryLines.filter { RunOutputFilter.undecorated($0).hasPrefix("Test run with ") }
        return tallyLines.enumerated().compactMap { index, line in
            guard let tally = RunTestTally.parse(line) else {
                return nil
            }
            let counts = "\(pluralized(tally.tests, "test")) in \(pluralized(tally.suites, "suite"))"
            let position = tallyLines.count > 1 ? "bundle \(index + 1) of \(tallyLines.count), " : ""
            return arithmeticLine(for: tally, bundle: "\(position)\(counts)")
        }
    }

    /// One bundle's arithmetic line, or `nil` where it recorded no known issue and so has nothing this line adds over its own tally.
    private func arithmeticLine(for tally: RunTestTally, bundle: String?) -> String? {
        guard tally.knownIssues > 0 else {
            return nil
        }
        let failures = pluralized(tally.failures, "failure")
        let known = pluralized(tally.knownIssues, "known issue")
        let label = bundle.map { " (\($0))" } ?? ""
        return "  Swift Testing\(label): \(failures), \(known)"
    }

    private func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The one line, last among this answer's content, whose presence or absence a gate can name — every other line above it can vary in count and shape, so this is the only one worth grepping for.
    ///
    /// `totals:` is the token: lowercase, stable across every shape below, and never a prefix a per-bundle line prints — a Swift Testing tally opens on `Test run with `, its known-issue arithmetic on `Swift Testing` — so a gate naming it can never match the wrong line. **Anchored — `grep '^totals:'`, never a bare `grep totals:`.** A listed failure's own message can carry the token: the assertions in `RunTotalsLineTests` do, and `Fixtures/RunOutput/swift-test-quoted-totals.txt` is a real run whose failure message quotes one, so an unanchored grep reads a quoted line as this one and would do it first the next time this line regresses.
    ///
    /// Present for every run under ``RunVerdict/Contract/runTally`` — `swift test`'s own contract — one whose tests never started included: a gate cannot tell a missing line from a binary older than the line, so a run that printed no closing count says exactly that here rather than leaving the reader to read absence. A `swift build` answer is unchanged by this line's existence, since it never carries either tally shape below.
    ///
    /// **Present for any other contract too, once the log actually carried one of the two tally shapes.** `xcodebuild test` owes `` .declares`` its own `** TEST … **` stamp rather than `.runTally`'s, but it launches the same Swift Testing and XCTest processes `swift test` does, and ``RunOutputFilter/recordSummary(_:)`` reads their closing lines the same way regardless of contract — so before this, a red `xcodebuild test` run over a large suite carried no derived total at all, only the raw tally sentence sitting among the summaries above, indistinguishable at a glance from every other line up there. A `swift build` or a clean `xcodebuild build` still prints nothing here, because neither ever populates `swiftTesting` or `xctest` below.
    ///
    /// **The word is ``RunReport/verdict``'s, never a tally's own.** `RunVerdict` already reads both frameworks and every bundle (``RunOutputFilter/runTallyVerdict(_:)``), while a tally's `passed` is a statement about Swift Testing's half of one process — so taking the glyph from the first and the word from the second is how this line came to print `✘ 1 test in 0 suites passed` over a failing `XCTestCase`: green to `grep passed` on a red run, which is the one output this command must never produce. The word is stated once, at the front, and no clause beneath it carries `passed` or `failed` of its own; the anomalies word it `reports a pass`, so the literal `passed` appears in this line only when the run did.
    ///
    /// **Both frameworks are counted, each under its own name.** Swift Testing closes on `Test run with N tests in M suites` and XCTest on `Executed N tests, with M failures` — one of each per test *product*, from the two separate processes it launches (see ``RunReport/testProcessOpenings``) — and a line reading only the first omits every `XCTestCase` the run executed: Swift Testing prints `Test run with 0 tests in 0 suites passed` for a package holding no `@Test` at all, so an XCTest-only suite of hundreds closed on a count of nothing. Labelled rather than merged because the denominators differ: XCTest's counter states no suite count, so `in M suites` can only ever be Swift Testing's. **Under `--parallel` this counter cannot be trusted the same way** — see the anomaly ``totalsHead(_:exitCode:bundles:)`` states for it.
    ///
    /// **Summed within a framework, never across the two.** A gate wants one number, and within one framework there is an honest one: more than one line of the *same* shape cannot be two frameworks over one target set — a single process running both prints one `Test run with …` and one `Executed …`, two different shapes — so two `Test run with …` lines are two Swift Testing runs, which is two processes, which is two bundles, and the bundles of a package are disjoint (`swift test --list-tests` counts exactly their sum). The sum is stated `across N bundles`, so the number carries the population it is over, and each addend is the tool's own line: always in the raw log, and printed among the summary lines directly above this one wherever the sum is anything but a plain pass or fail (``shown(_:of:beside:)``) — which is what keeps Docs/Design.md §3's *every count is the tool's own* intact rather than bent: the one derived number in this answer is checkable against the tool's own lines. Across the two frameworks nothing is summed, and it could not be stated in the shape a reader wants anyway: `N tests in M suites` has no honest `M` there, since XCTest's counter states no suite count. A line that will not parse is never summed either — several keep the earlier wording, `N tallies, not summed`, a lone one reads `tally 1 unreadable`, and either way the tool's own lines stay above it.
    ///
    /// **A process that opened and printed no closing count is named.** ``RunReport/testProcessOpenings`` and ``RunReport/testProcessClosings`` are each a sum over both frameworks' processes, so a closing count owed and never printed shows as fewer closings than openings whichever process is missing it — a bundle that crashed, hit a `fatalError` or timed out otherwise leaves a surviving process's count standing for the whole run.
    ///
    /// **And so is a bundle that never launched, once something outside the log says how many there should have been.** A test target that failed to compile announces nothing — no opening, no tally, no counter — so no count taken from the log can miss it, and every surviving line still says `passed`: the case this line exists for. ``RunTestBundles`` carries the expectation from the package's own manifest, and where it is ``RunTestBundles/undetermined`` this clause is simply absent, leaving the claim worded over the processes that started exactly as it was before.
    ///
    /// **That reachability clause and the display clause after it never share a phrase, because they count two different populations.** The reachability clause above counts *closings* — deliberately including a vestigial XCTest counter (`Executed 0 tests, with 0 failures`), since a process that prints only that still closed. The display clause counts what is worth *showing*: ``xctestCounts(_:)`` and ``swiftTestingCounts(_:)`` both exclude that same vestigial counter, so a run where nothing survives that filter says so in its own words rather than restating "printed a closing count" over a different denominator, which reads as the two clauses contradicting each other. What it says is ``nothingToDisplay(_:)``'s, and the reason it gives is read off the run rather than assumed: the shapes that reach it are no process announcing itself (a build that failed first, a selector that matched nothing, or neither), a process that died, and a run whose only closing counts were vestigial, and each is a different fact.
    ///
    /// **A verdict that reads as a pass over a nonzero exit is the headline first, but this line says so too.** A gate that greps only this line must see the same anomaly the headline already names above it.
    private func totalsLine(_ report: RunReport, exitCode: Int32) -> RunTotals? {
        let swiftTesting = report.summaryLines.filter { RunOutputFilter.undecorated($0).hasPrefix("Test run with ") }
        let xctest = report.summaryLines.filter { $0.hasPrefix("Executed ") }
        let owesThisLine: Bool = switch report.contract {
        case .runTally: true
        case .declares: !swiftTesting.isEmpty || !xctest.isEmpty
        case .diagnostics, .unreadable: false
        }
        guard owesThisLine else {
            return nil
        }
        let counted = [xctestCounts(xctest), swiftTestingCounts(swiftTesting, skipped: swiftTestingSkips(report))].compactMap(\.self)
        let described = counted.isEmpty ? nothingToDisplay(report, exitCode: exitCode) : counted.joined(separator: " · ")
        let reported = report.reportedBundleCount
        let everyTallySummed = swiftTesting.allSatisfy { RunTestTally.parse(String(RunOutputFilter.undecorated($0))) != nil }
            && xctest.allSatisfy { RunOutputFilter.ExecutedCounts(line: $0) != nil }
        return RunTotals(
            line: "totals: \(totalsHead(report, exitCode: exitCode, bundles: reported)) · \(described)",
            everyTallySummed: everyTallySummed
        )
    }

    /// The display clause where no count survived the filter — true of its own population in every shape, never of the shape its first caller happened to observe.
    ///
    /// `nothing to display` is the part that is always true: it is a statement about what this clause counts, which is what is worth *showing*. What follows `since` is the reason, and the three shapes that reach here are three different facts a reader acts on, so only one of them can be named at a time.
    ///
    /// No process announcing itself is three facts, told apart by evidence rather than assumed: a build that failed first (a compiler or linker error and no test line, ``RunTestSelector/buildFailedFirst(_:exitCode:)``) is the only one that says no test process *started*; a selector that matched nothing says no test ran, which its evidence shows, and never that no process started, which the log cannot show — SwiftPM may launch the test binary to find there is nothing to run; anything else says only what the log shows, that no test process announced it started. Fewer closings than openings is a process that died. Openings matching closings with nothing left to show is the vestigial case: the run closed properly and printed no number worth a reader's time. Only the process-died shape can appear beside the reachability clause, which prints solely where a closing is owed and missing, so no two of these are ever on one line.
    private func nothingToDisplay(_ report: RunReport, exitCode: Int32) -> String {
        if report.testProcessOpenings == 0 {
            if RunTestSelector.buildFailedFirst(report, exitCode: exitCode) {
                return "nothing to display, since no test process started"
            }
            if let selector, selector.matchedNothing(report, exitCode: exitCode) {
                return "nothing to display, since no test ran"
            }
            return "nothing to display, since no test process announced that it started"
        }
        if report.testProcessOpenings > report.testProcessClosings {
            return "nothing to display, since a process died before printing anything worth showing"
        }
        return "nothing to display, since every closing count printed was vestigial"
    }

    /// The head of the totals line: one glyph, one word for how the run ended, and every anomaly that stops either from being read at face value.
    ///
    /// The anomalies are what keep the word honest without a second judgement of the log: the word stays ``RunVerdict/state``'s, and where that state cannot be taken at face value — a pass over a nonzero exit, a pass with a process unheard from, a pass with a bundle that never reported at all, a run under `--parallel` — the glyph turns to `⚠` and the clause after the dash says which. Neither anomaly spells `passed`, so the word at the front is the only place that literal can appear.
    ///
    /// **The two silences are different claims and are worded apart.** A process that opened and printed nothing is a fact of the log, counted over the processes that started; a bundle that never opened at all is a fact about the *package*, counted against what ``RunTestBundles`` says its manifest declares — and named as such, so a reader can see where that denominator came from and that it is not the log's.
    private func totalsHead(_ report: RunReport, exitCode: Int32, bundles reported: Int) -> String {
        if let selector, selector.matchedNothing(report, exitCode: exitCode) {
            return selector.totalsHead
        }
        if let selector, selector.didNotBuild(report, exitCode: exitCode) {
            return RunTestSelector.didNotBuildTotalsHead
        }
        if let selector, case let unmatched = selector.unmatchedFilters(report, exitCode: exitCode), !unmatched.isEmpty {
            return selector.totalsHead(unmatched: unmatched)
        }
        if let declared = testBundles.count, RunTestSelector.executedNothing(report, exitCode: exitCode, testBundles: testBundles) {
            return RunTestSelector.executedNothingTotalsHead(declared: declared)
        }
        let silent = report.testProcessOpenings - report.testProcessClosings
        // Nothing where the expectation is undetermined: `reported` against itself is never a shortfall, which
        // is the whole of "an undetermined expectation prints nothing".
        let unreported = (testBundles.count ?? reported) - reported
        var anomalies: [String] = []
        if silent > 0 {
            let processes = report.testProcessOpenings == 1 ? "test process" : "test processes"
            anomalies.append("\(report.testProcessClosings) of \(report.testProcessOpenings) \(processes) printed a closing count")
        }
        if let expected = testBundles.count, unreported > 0 {
            let bundles = expected == 1 ? "test bundle" : "test bundles"
            anomalies.append("\(reported) of \(expected) \(bundles) the package declares printed a count")
        }
        if report.parallelSwiftTest {
            anomalies.append("run with --parallel, whose own per-test progress lines are not counted here")
        }
        var glyph: String
        let word: String
        switch report.verdict?.state {
        case .succeeded where exitCode != 0:
            glyph = "⚠"
            word = "exit code disagrees"
            anomalies.append("every count this answer read reports a pass but the command exited \(exitCode)")
        case .succeeded where silent > 0 || unreported > 0:
            glyph = "⚠"
            word = "incomplete"
            // Named for whichever silence there is: a process that opened and said nothing, or a bundle that
            // never opened. They are different claims, so the sentence never calls one the other.
            let unheard = silent > 0 ? "process" : "bundle"
            anomalies.append("every count this answer read reports a pass, and none of them speaks for the \(unheard) that printed none")
        case .succeeded:
            glyph = "✔"
            word = "passed"
        case .failed where report.testCrash != nil:
            glyph = "✘"
            word = "crashed"
        case .failed:
            glyph = "✘"
            word = "failed"
        default:
            // `nil` — the only other state ``RunOutputFilter/runTallyVerdict(_:)`` can hand back for this
            // contract; `.interrupted` is a real case of `RunVerdict.State` but not one it ever returns.
            glyph = "⚠"
            word = "no verdict in the log"
        }
        if report.parallelSwiftTest, ["passed", "failed", "crashed"].contains(word) {
            // The word is still the verdict's own — `--parallel` does not make a pass read as a failure or
            // the reverse — but the glyph joins every other anomaly's in turning to a warning, because the
            // count beside the word cannot be taken at face value either.
            glyph = "⚠"
        }
        guard !anomalies.isEmpty else {
            return "\(glyph) \(word)"
        }
        return "\(glyph) \(word) — \(anomalies.joined(separator: "; "))"
    }

    /// Swift Testing's own counts — one number across the run's bundles where they can all be read, and tally by tally where one cannot — or `nil` where it printed none.
    ///
    /// **Named after the framework that printed them, because that is the denominator they are over.** The suite count is Swift Testing's alone — XCTest's counter has none — and a run's `XCTestCase`s are nowhere in these numbers.
    ///
    /// **One tally is one bundle**, so several are summed and the sum says `across N bundles`: two lines of this same shape cannot be two frameworks over one target set (a process running both prints one of each shape, not two of one), so they are two Swift Testing runs in two processes over two disjoint bundles. A line that will not parse stops the sum rather than being left out of it — a total missing an addend nobody can see is worse than no total — and the run then states every count it read, in the order it read them, with how many of them there were.
    ///
    /// `skipped` is how many of the run's Swift Testing tests its own lines reported skipped, which its tally counts among its tests as XCTest's counter counts an `XCTSkip`, and is said once for the whole clause.
    private func swiftTestingCounts(_ lines: [String], skipped: Int) -> String? {
        guard !lines.isEmpty else {
            return nil
        }
        let tallies = lines.map { RunTestTally.parse(String(RunOutputFilter.undecorated($0))) }
        let readable = tallies.compactMap(\.self)
        if lines.count > 1, readable.count == lines.count {
            let tests = readable.reduce(0) { $0 + $1.tests }
            let suites = readable.reduce(0) { $0 + $1.suites }
            let failures = readable.reduce(0) { $0 + $1.failures }
            return "Swift Testing \(pluralized(tests, "test")) in \(pluralized(suites, "suite")) across \(pluralized(lines.count, "bundle"))\(failureNote(failures))\(skipNote(skipped))"
        }
        let described = tallies.enumerated().map { index, tally -> String in
            guard let tally else {
                return "tally \(index + 1) unreadable"
            }
            return "\(pluralized(tally.tests, "test")) in \(pluralized(tally.suites, "suite"))\(failureNote(tally.failures))"
        }.joined(separator: "; ")
        guard lines.count > 1 else {
            return "Swift Testing \(described)\(skipNote(skipped))"
        }
        // Said apart from the last tally, since the run's lines cannot say which tally each skip belongs to.
        return "Swift Testing \(lines.count) tallies, not summed — \(described)\(skipped > 0 ? "; \(skipped) skipped across them" : "")"
    }

    /// How many Swift Testing tests the run's own lines last reported skipped (a `.disabled` test, one a trait or a cancellation skipped), counted from the skip lines the runner printed.
    ///
    /// Summed over each name's tally rather than counted by name: Swift Testing prints no suite beside a function's name, so two suites that each skip `anOrdinaryPass()` print one name twice, and a name's last ending alone would count them once or, where a passing twin ended last, not at all.
    private func swiftTestingSkips(_ report: RunReport) -> Int {
        let outcomes = report.testOutcomes
        return outcomes.swiftTestingNames.reduce(0) { $0 + (outcomes.tallies[$1]?.skipped ?? 0) }
    }

    /// XCTest's own counters, one per test process, or `nil` where it printed none — the half of a run a Swift Testing tally says nothing about.
    ///
    /// Summed on the same terms as the tallies above, and `across N bundles` counts the bundles that printed a counter *worth showing*: a bundle whose only `Executed …` line is `xcodebuild` boilerplate is filtered out upstream (``RunOutputFilter/isVestigialCounter(_:)``), so this population is the display clause's and never the reachability clause's.
    private func xctestCounts(_ lines: [String]) -> String? {
        guard !lines.isEmpty else {
            return nil
        }
        let counters = lines.map { RunOutputFilter.ExecutedCounts(line: $0) }
        let readable = counters.compactMap(\.self)
        if lines.count > 1, readable.count == lines.count {
            let tests = readable.reduce(0) { $0 + $1.tests }
            let failures = readable.reduce(0) { $0 + $1.failures }
            let skipped = readable.reduce(0) { $0 + $1.skipped }
            return "XCTest \(pluralized(tests, "test")) across \(pluralized(lines.count, "bundle"))\(failureNote(failures))\(skipNote(skipped))"
        }
        let described = counters.enumerated().map { index, counts -> String in
            guard let counts else {
                return "counter \(index + 1) unreadable"
            }
            return "\(pluralized(counts.tests, "test"))\(failureNote(counts.failures))\(skipNote(counts.skipped))"
        }.joined(separator: "; ")
        guard lines.count > 1 else {
            return "XCTest \(described)"
        }
        return "XCTest \(lines.count) counters, not summed — \(described)"
    }

    /// One framework's failure count where it reported any, and nothing where it reported none — never the word `failed`, which is the run's and is stated once, at the front.
    private func failureNote(_ failures: Int) -> String {
        failures > 0 ? ", \(pluralized(failures, "failure"))" : ""
    }

    /// How many of a framework's tests were skipped, where any were — an XCTest counter's `XCTSkip`s, or the Swift Testing tests the run's lines reported skipped — so a run whose every selected test skipped is not read as that many tests run and passed.
    private func skipNote(_ skipped: Int) -> String {
        skipped > 0 ? ", \(skipped) skipped" : ""
    }

    /// How many lines the two sections that can list have between them.
    ///
    /// **The receipt states this answer's size against the log's, and a listing long enough to make that a loss is not a compression at all.** A listed test failure costs two to four lines against as few as one or two of log — twenty Swift Testing tests recording three issues each print about 110 lines and would list as 126 — so the wrapper would be expanding exactly what it exists to shrink, and saying so in its own receipt. A count cap would bound that only by accident; this is the code that holds it, once the form is decided on size alone, and `RunOutputFilterTests` asserts the property over the corpus.
    ///
    /// **It bounds every line the answer prints, including the ones this repository added.** ``RunFailureCensus/listing(of:within:spending:entries:)`` charges it ``RunFailureCensus/Entry/lines`` and not ``RunFailureCensus/Entry/charged`` — which is the opposite of what the size budget beside it charges, and deliberately so. That budget decides a *form* and may not be moved by anything the reader brought with them; this one is a claim about how long the answer is, and a resolved `in …` line is as much a line of it as the failure above it. Exempting them would make the receipt lie in the tool's own arithmetic: 52 resolving failures under a 110-line log would be charged 105 lines, print 162, and close on `raw: … (110 lines in, 162 out)`.
    ///
    /// What the log has left over is the honest allowance: everything else the answer prints has already been composed, and the one line left is the receipt that closes it. Nothing left is the right answer for a log too short to be worth standing in for — no listing fits in it, so both sections measure.
    ///
    /// **Clamped at zero, because one section is exempt from this bound and can otherwise spend the next one's share into nonsense.** ``RunErrorShape``'s sample prints an `Undefined symbols` block's symbol list whole — deliberately, since the header means nothing without it — so a linker dumping several hundred undefined symbols makes that block longer than the log it stands for, and subtracting it would leave a negative number standing where a count of lines belongs. Zero and a negative both refuse a listing, so the failures beneath it sample either way; what the clamp fixes is the arithmetic, and the exemption itself is documented where it is taken rather than papered over here. The receipt says the rest out loud — an answer with such a block in it can read more out than in, and that is the honest number.
    func allowance(of report: RunReport, beside printed: Int) -> Int {
        allowance(of: report, beside: printed, notes: deviceNotes(of: report).lines.count)
    }

    private func allowance(of report: RunReport, beside printed: Int, notes: Int) -> Int {
        max(0, report.totalLines - printed - 1 - notes)
    }

    /// The line each simulator this run named owes the answer, in the order argv named them, and whether they lead the failures.
    ///
    /// **Whether a device owes a line depends on the failures**, which is why the notes are asked of the report rather than of the devices alone: a preference that read on throughout is said nothing about unless the failures have the shape of an empty accessibility tree, and wherever they do, every device line leads the failure block — it is the first thing the reader has to act on, and a line under the receipt is the last thing they read.
    func deviceNotes(of report: RunReport) -> DeviceNotes {
        let emptyTrees = readsEmptyTrees(report)
        return DeviceNotes(
            lines: accessibility.compactMap { $0.note(failuresReadEmptyTrees: emptyTrees) },
            leadFailures: emptyTrees
        )
    }

    /// Whether this run's failures have the shape of an empty in-process accessibility tree; never asked of a run that put no test on a simulator.
    private func readsEmptyTrees(_ report: RunReport) -> Bool {
        guard !accessibility.isEmpty, !report.testFailures.isEmpty else {
            return false
        }
        return failureShape(of: report).dominantClass?.readsEmptyTree == true
    }

    /// The errors as a listing while a listing of them is still the better answer, and as a shape once it is not — a build that changes one argument label can print 200 of one sentence.
    ///
    /// Paths reach the shape as the run spelled them and are made relative when a line is composed, which is ``RunAnswerPaths``'s whole subject: where the answer is read decides how a path is *printed* and must decide nothing about how much of the answer there is.
    private func errorSection(_ report: RunReport, within allowance: Int, spending budget: inout Int) -> [String] {
        let shape = RunErrorShape.of(report.errors, changedFiles: changedFiles, paths: paths)
        // One line of the allowance goes on the blank line this section opens with, which is as much a
        // part of what the answer costs as the block beneath it.
        let block = shape.rendered(within: allowance - 1, spending: &budget)
        return block.isEmpty ? [] : [""] + block
    }

    /// The failures as a listing while one is still worth serving, and as a shape once it is not — a count of failures is not a diagnosis, and 666 of them are not an answer.
    ///
    /// The measurement line heads the listing as well as the shape wherever there is more than one failure, with no `test failures (N):` heading beside it: such a heading's only content would be the count, which is that line's first field. Locations reach the shape as the framework printed them, for the reason the errors above do.
    ///
    /// - Parameter leading: The device lines that lead the block, already charged to `allowance` by its caller.
    private func testFailureSection(_ report: RunReport, leadingWith leading: [String], within allowance: Int, spending budget: inout Int) -> [String] {
        guard !report.testFailures.isEmpty else {
            return []
        }
        let shape = failureShape(of: report)
        let block = shape.renderedNaming(within: allowance, spending: &budget)
        return leading + block.lines + failingByFile(of: shape, naming: block.named, within: allowance - block.lines.count)
    }

    /// The failing tests grouped by file, where the block above left some unnamed or without their file and the log has room left for it.
    ///
    /// The room is the same bound ``allowance(of:beside:)`` states for the listing: an answer that grew past the log it stands for would print a receipt saying it saved nothing, and the raw log keeps what this leaves out.
    private func failingByFile(of shape: RunFailureShape, naming named: Set<String>, within allowance: Int) -> [String] {
        let lines = RunFailingByFile(failures: shape.failures, named: named).rendered()
        return lines.count <= allowance ? lines : []
    }

    /// The report's test failures measured as the failure block measures them.
    private func failureShape(of report: RunReport) -> RunFailureShape {
        RunFailureShape.of(
            report.testFailures.map { failure in
                RunFailureShape.Failure(
                    name: failure.name,
                    location: failure.location,
                    message: failure.message,
                    arguments: failure.arguments,
                    note: failure.note,
                    closestLine: failure.closestLine
                )
            },
            changedFiles: changedFiles,
            sites: sites,
            paths: paths,
            accessibility: accessibility
        )
    }

    private func warningSection(_ report: RunReport) -> [String] {
        guard !report.warnings.isEmpty else {
            return []
        }
        // A linter's warnings are the whole of its output — one line per violation, hundreds of them, almost
        // always a handful of rules repeated — so they earn the same by-signature grouping an errors listing
        // already gives a build. A build or test's warnings stay the flat,
        // capped listing below: this is the shape those fixtures assert, and a build's warnings are rarely one
        // rule repeated the way a linter's are.
        guard kind == .linter else {
            var lines = ["", "warnings (\(report.warnings.count)):"]
            lines.append(contentsOf: report.warnings.prefix(RunOutputFilter.warningCap).map { "  \(paths.shown($0).described)" })
            let withheld = report.warnings.count - RunOutputFilter.warningCap
            if withheld > 0 {
                lines.append("  +\(withheld) more warnings — see the raw log")
            }
            return lines
        }
        let shape = RunErrorShape.of(report.warnings, changedFiles: changedFiles, paths: paths, noun: "warning")
        let block = shape.rendered()
        return block.isEmpty ? [] : [""] + block
    }

    /// The tail every filtered answer ends on: what it stood in for, what it cost, and where the rest of it is.
    ///
    /// **"N in, M out" rather than a count of what was suppressed**, because M is the answer's own line count, measured on the text being returned. Subtracting a count the filter accumulates while parsing — every input line whose text survived *somewhere* — stops describing the answer the moment the failures are served as a shape instead of a listing: over a thousand lines counted as shown against a couple of dozen printed, a receipt understating the saving by nearly the whole log on the one answer this command is built for. The number an answer states about itself has to come from the answer, or the two are free to drift apart, and the receipt is the line the whole compression is trusted on.
    private func receipt(_ report: RunReport, answerLines: Int, logURL: URL?) -> String {
        let arithmetic = "(\(report.totalLines) lines in, \(answerLines) out)"
        guard let logURL else {
            return "raw: none \(arithmetic) — the raw log could not be written, so what is above is all there is"
        }
        return "raw: \(paths.shown(logURL.path)) \(arithmetic)"
    }

    /// The summary lines this answer prints: every one of ``summaries(of:)``, less those a plain totals line already restates.
    ///
    /// A totals line that reads `✔ passed` or `✘ failed` with every tally read and summed (``RunTotals/everyTallySummed``, taken from the tallies rather than the line's words) is the tool's own tallies in one line, and the verdict's; the tally and counter lines it was summed from, and any line declaring that same state, would say it a second time. Anything short of that keeps them all: an anomaly, a tally left unsummed, or a verdict that is not the invoked command's is where the tool's own lines are the evidence the reader checks the answer against.
    func shown(_ summaries: [String], of report: RunReport, beside totals: RunTotals?) -> [String] {
        guard report.contract == .runTally, let totals, totals.everyTallySummed, let verdict = report.verdict,
              verdict.answersTheInvokedCommand, !verdict.inferredFromExitCode,
              totals.line.hasPrefix("totals: ✔ passed · ") || totals.line.hasPrefix("totals: ✘ failed · ")
        else {
            return summaries
        }
        return summaries.filter { line in
            let undecorated = RunOutputFilter.undecorated(line)
            let tally = undecorated.hasPrefix("Test run with ") || line.hasPrefix("Executed ")
            return !tally && RunVerdict.state(of: line) != verdict.state
        }
    }
}

public extension RunReportRenderer {
    /// The lines a run's simulators owe its answer, and where they go.
    struct DeviceNotes: Sendable, Equatable {
        /// One per device that owes a line, in argv order.
        public let lines: [String]
        /// Whether they lead the failure block rather than sit under the receipt.
        public let leadFailures: Bool
    }
}

public extension RunReportRenderer {
    /// `raw` as the fallback prints it: every line past ``lineCap`` bytes cut there and marked with where the raw log is, every other byte as it was.
    ///
    /// The fallback serves the whole transcript because the filter found nothing that says why the run failed, and that is a reason to print every line, not every byte of one: a frontend command line quoted whole is tens of kilobytes the reader cannot act on. The log on disk keeps it, and the marker names that log. The cut backs off to the start of a UTF-8 sequence so no character is split, and the count is in bytes, since a transcript need not be text at all.
    static func clippingLongLines(of raw: Data, log: URL) -> Data {
        let bytes = [UInt8](raw)
        guard bytes.count > lineCap else {
            return raw
        }
        var clipped = Data()
        clipped.reserveCapacity(bytes.count)
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            if end - start > lineCap {
                var cut = start + lineCap
                while cut > start, bytes[cut] & 0xC0 == 0x80 {
                    cut -= 1
                }
                clipped.append(contentsOf: bytes[start ..< cut])
                clipped.append(contentsOf: Array("… (+\(end - cut) bytes — the raw log keeps this line whole: \(log.path))".utf8))
            } else {
                clipped.append(contentsOf: bytes[start ..< end])
            }
            if end < bytes.count {
                clipped.append(UInt8(ascii: "\n"))
            }
            start = end + 1
        }
        return clipped
    }
}
