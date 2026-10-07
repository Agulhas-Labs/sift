//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one line `RunReportRenderer.render(_:exitCode:logURL:)` appends last, so a gate has a single stable token to name: `totals:`.
///
/// The per-bundle lines above it are covered by `RunMultiBundleKnownIssueTests`; this file covers only the summary line itself — the word it takes from the verdict, the counts it takes from both frameworks, what it refuses to sum, what it says about a process that printed nothing, and that it says nothing at all for a command that never carries either tally shape (`swift build`). **It also always carries one where either shape is present, whichever contract printed it** — `swift test` owes it unconditionally under `.runTally`, and `xcodebuild test` earns it too once its log holds a `Test run with …` or `Executed …` line, red or green: before that, a failed `xcodebuild test` run over a large suite carried no derived total at all, only the raw tally sentence sitting among the summaries above it.
///
/// **The assertions here contain the token, which is why the gate is `grep '^totals:'`.** A failure in this file prints its expected string, token and all, so an unanchored grep over a red run of this very suite would match the assertion rather than the answer's own line — the same self-reference `Fixtures/RunOutput/swift-test-quoted-tally.txt` exists for one line further up, and `swift-test-quoted-totals.txt` is the real capture of it for this one.
struct RunTotalsLineTests {
    private static var workingDirectory: URL {
        URL(fileURLWithPath: "/Users/dev/Depot")
    }

    private static func answer(_ report: RunReport, exitCode: Int32, bundles: RunTestBundles = .undetermined) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: workingDirectory, testBundles: bundles)
            .render(report, exitCode: exitCode, logURL: nil)
    }

    /// The one line a gate would match: the line that *begins* with the token, and `nil` unless there is exactly one of those.
    private static func totalsLine(of answer: String) -> String? {
        let anchored = answer.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("totals:") }
        guard anchored.count == 1 else {
            return nil
        }
        return String(anchored[0])
    }

    /// A single Swift Testing tally speaks for its own half of the run, and the word in front of it is the verdict's.
    @Test
    func aSingleTallySpeaksForTheWholeRun() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.")
        let report = filter.finish(exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ✔ passed · Swift Testing 29 tests in 4 suites")
    }

    /// A failing tally names its own failure count, and the word is the one `RunReport.verdict` read — not a second judgement of the same line.
    @Test
    func aSingleFailingTallyNamesItsOwnFailures() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 2 issues.")
        let report = filter.finish(exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · Swift Testing 6 tests in 3 suites, 2 failures")
    }

    /// The failing `XCTestCase` a Swift Testing tally says nothing about — the defect this line went back for.
    ///
    /// `swift test` runs both frameworks in one process, and Swift Testing's closing sentence is a statement about its own half: a package whose `XCTestCase` failed while its `@Test` passed closes on `Test run with 1 test in 1 suite passed`, so a line built from that tally alone printed `✘ 1 test in 1 suite passed` — one of the run's two tests counted, and the sentence ending on the word a gate greps for. The word here is the verdict's, and both halves are counted under the name of the framework that printed them.
    @Test
    func aFailingXCTestHalfIsNeverClosedOnSwiftTestingsPass() throws {
        let report = try TestSources.runReport("swift-test-mixed-xctest-failure", invokedAs: ["swift", "test"], exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · XCTest 1 test, 1 failure · Swift Testing 1 test in 1 suite")
        #expect(!line.contains("passed"))
    }

    /// A package with no `@Test` at all is never closed on Swift Testing's count of nothing.
    ///
    /// Swift Testing prints `Test run with 0 tests in 0 suites passed` whether or not a package holds one, so a line that reads only that sentence reports a suite of hundreds of `XCTestCase` tests as `0 tests in 0 suites passed` — the run's whole content missing and the verb wrong at once.
    @Test
    func anXCTestOnlyRunIsNeverClosedOnACountOfNothing() throws {
        let report = try TestSources.runReport("swift-test-xctest-only-failure", invokedAs: ["swift", "test"], exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · XCTest 1 test, 1 failure · Swift Testing 0 tests in 0 suites")
        #expect(!line.contains("0 tests in 0 suites passed"))
    }

    /// A `swift test --filter` that selects only `XCTestCase` tests starts no Swift Testing process, so XCTest's counter is the only closing count the run owes — and it is heard from, so the run passed.
    ///
    /// Before, every such run answered `⚠ … no verdict in the log`: the process opens on `Test Suite 'Selected tests' started at`, which was not read as an opening, and the counter's `with 1 test skipped and` clause was not read at all.
    @Test
    func aFilteredXCTestOnlyRunWhoseTestSkippedIsAPassThatNamesTheSkip() throws {
        let report = try TestSources.runReport("swift-test-xctest-filter-skipped", invokedAs: ["swift", "test", "--filter", "XT/testSkipsOutright"], exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(report.verdict?.state == .succeeded)
        #expect(line == "totals: ✔ passed · XCTest 1 test, 1 skipped")
    }

    /// Each filtered XCTest process opens on its own `'Selected tests'` suite, so two bundles are two counters and are summed, never one bundle's counter standing in for both.
    @Test
    func aFilteredRunAcrossTwoXCTestBundlesCountsBoth() throws {
        let report = try TestSources.runReport("swift-test-xctest-filter-two-bundles", invokedAs: ["swift", "test", "--filter", "XT"], exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ✔ passed · XCTest 4 tests across 2 bundles, 1 skipped")
    }

    /// A filtered XCTest process that opened and never closed is not a pass, whatever the process before it printed.
    @Test
    func aFilteredXCTestProcessThatNeverClosedIsNoPass() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.346.",
            "\t Executed 2 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.405.",
        ] {
            filter.consume(line: line)
        }

        #expect(filter.finish(exitCode: 0).verdict == nil)
    }

    /// A filtered XCTest process that died after one suite finished has printed that suite's counter and never the end of `'Selected tests'`, so it is no pass: a test calling `exit(0)` in the second of two selected suites printed exactly this.
    @Test
    func aFilteredXCTestProcessThatDiedAfterOneSuiteIsNoPass() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.346.",
            "Test Suite 'GadgetTests.xctest' started at 2000-01-01 12:00:00.346.",
            "Test Suite 'LegacyTests' started at 2000-01-01 12:00:00.346.",
            "Test Case '-[GadgetTests.LegacyTests testOne]' started.",
            "Test Case '-[GadgetTests.LegacyTests testOne]' passed (0.000 seconds).",
            "Test Suite 'LegacyTests' passed at 2000-01-01 12:00:00.347.",
            "\t Executed 1 test, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "Test Suite 'BetaTests' started at 2000-01-01 12:00:00.347.",
            "Test Case '-[GadgetTests.BetaTests testTwo]' started.",
        ] {
            filter.consume(line: line)
        }

        #expect(filter.finish(exitCode: 0).verdict == nil)
    }

    /// The shape this repository's own `sift run -- swift test` prints on itself: two `Test run with` lines, one per test bundle, both passed — and one number a gate can read, named for the population it is over.
    ///
    /// Two lines of the *same* shape cannot be two frameworks over one target set: a single process running both prints one `Test run with …` and one `Executed …`, two different shapes. So two of these are two Swift Testing runs, which is two processes, which is two bundles, and a package's bundles are disjoint — measured on this repository, the two counts add to exactly what `swift test --list-tests` enumerates, and the one suite name they share exists once in each test target. Every addend stays printed verbatim among the summary lines above, so the one derived number in this answer is checkable against the tool's own.
    @Test
    func twoPassingTalliesAreSummedAcrossTheBundlesThatPrintedThem() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 1145 tests in 94 suites passed after 72.138 seconds.",
            "✔ Test run with 1553 tests in 134 suites passed after 81.741 seconds with 2 known issues.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ✔ passed · Swift Testing 2698 tests in 228 suites across 2 bundles")
        #expect(!line.contains("tallies"))
    }

    /// A test that echoes a nested run's answer prints `Test run with …` at the start of an indented line, and that is the test's own output, never a tally of this run: read as one it is unparseable and gives up the verdict of a green run.
    @Test
    func indentedTallyLinesAreATestsOwnOutputAndNeverTallies() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "  Test run with 1 test in 1 suite passed",
            "  Test run with 1 test in 1 suite passed",
            "✔ Test run with 29 tests in 3 suites passed after 2.456 seconds.",
            "  Test run with 1 test in 1 suite passed",
            "  Test run with 1 test in 1 suite passed",
            "  Test run with 1 test in 1 suite passed",
            "✔ Test run with 38 tests in 2 suites passed after 3.100 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ✔ passed · Swift Testing 67 tests in 5 suites across 2 bundles")
        #expect(!line.contains("unreadable"))
    }

    /// A tally the parser cannot read stops the sum rather than being left out of it — a total missing an addend nobody can see is worse than no total — and the run states every count it read, the way it did before any of them could be added.
    @Test
    func anUnreadableTallyStopsTheSumInsteadOfBeingLeftOutOfIt() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.",
            "✔ Test run with several tests in 4 suites passed after 0.047 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ⚠ no verdict in the log · Swift Testing 2 tallies, not summed — 29 tests in 4 suites; tally 2 unreadable")
    }

    /// One process printing one line of *each* shape is the two frameworks over one target set, and is never added up: the counts stay labelled apart, because `N tests in M suites` has no honest `M` across the two.
    @Test
    func oneProcessPrintingBothShapesIsTwoFrameworksAndIsNeverSummed() throws {
        let report = try TestSources.runReport("swift-test-mixed-xctest-failure", invokedAs: ["swift", "test"], exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        // One of each shape, from one process — so there is one bundle here, and nothing to sum.
        #expect(report.testProcessOpenings == 2)
        #expect(line == "totals: ✘ failed · XCTest 1 test, 1 failure · Swift Testing 1 test in 1 suite")
        #expect(!line.contains("across"))
        #expect(!line.contains("2 tests"))
    }

    /// XCTest's counters are summed on the same terms, over the bundles that printed one worth showing.
    @Test
    func xctestCountersAreSummedAcrossTheBundlesThatPrintedOne() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "\t Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.317) seconds",
            "Test Suite 'All tests' started at 2000-01-01 12:00:01.200.",
            "\t Executed 4 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · XCTest 16 tests across 2 bundles, 3 failures")
    }

    /// The case the line exists for: a bundle that never built printed nothing at all — no opening, no counter, no tally — while every line that did print says `passed`.
    ///
    /// Nothing in the log can see it: the one bundle that ran opened both its processes and closed both of them, so the reachability clause is satisfied and the verdict is a pass. What names it is the package's own manifest, through ``RunTestBundles`` — and the word turns to `incomplete`, because a count that speaks for one bundle of two is not a pass for the package.
    @Test
    func aBundleThatNeverReportedIsNamedThoughEverySurvivingLineSaysPassed() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "◇ Test run started.",
            "✔ Test run with 24 tests in 3 suites passed after 0.100 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        // Nothing the log holds is missing: the bundle that ran was heard from by both its processes.
        #expect(report.verdict?.state == .succeeded)
        #expect(report.testProcessOpenings == report.testProcessClosings)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0, bundles: .declaredByManifest(2))))
        #expect(line == "totals: ⚠ incomplete — 1 of 2 test bundles the package declares printed a count; every count this answer read reports a pass, and none of them speaks for the bundle that printed none · Swift Testing 24 tests in 3 suites")
        #expect(!line.contains("passed"))
    }

    /// And where nothing outside the log is in a position to say how many bundles there should have been, the line says nothing about one — the same answer it gave before the expectation existed.
    @Test
    func anUndeterminedExpectationClaimsNothingAboutABundleThatNeverReported() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "◇ Test run started.",
            "✔ Test run with 24 tests in 3 suites passed after 0.100 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ✔ passed · Swift Testing 24 tests in 3 suites")
    }

    /// One of several tallies failing reads the line as a failure, naming both tallies rather than only the one that failed.
    @Test
    func oneFailingTallyAmongSeveralReadsAsAFailure() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds.",
            "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 3 issues (including 1 known issue).",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · Swift Testing 10 tests in 5 suites across 2 bundles, 2 failures")
    }

    /// Every tally the log carries says passed while the command exited nonzero: the two claims disagree, and the line says so rather than closing on either.
    ///
    /// Worded `reports a pass` deliberately — the literal `passed` belongs to the verdict's own word at the front of the line, so a gate matching that literal cannot be made green by an anomaly that mentions one.
    @Test
    func everyTallyPassingOverANonzeroExitReadsAsADisagreementNotAPass() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds.",
            "✔ Test run with 6 tests in 3 suites passed after 0.020 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)

        #expect(report.verdict?.state == .succeeded)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))
        #expect(line == "totals: ⚠ exit code disagrees — every count this answer read reports a pass but the command exited 1 · Swift Testing 10 tests in 5 suites across 2 bundles")
        #expect(!line.contains("passed"))
    }

    /// A bundle that launched and printed no closing count is named, because the log itself says how many launched.
    ///
    /// XCTest opens every test process with `Test Suite 'All tests' started at`, so a run whose second bundle crashed, hit a `fatalError` or timed out carries two openings and one tally — and a line reading the tallies alone would print the surviving bundle's numbers as the run's. What no log states is a bundle that never launched: a test target that failed to compile announces nothing, so the claim is over the processes that started.
    @Test
    func aProcessThatOpenedAndPrintedNoCountIsNamed() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "✔ Test run with 2 tests in 1 suite passed after 0.010 seconds.",
            "Test Suite 'All tests' started at 2000-01-01 12:00:01.200.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)

        #expect(report.testProcessOpenings == 2)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))
        #expect(line.contains("1 of 2 test processes printed a closing count"))
        #expect(!line.contains("passed"))
    }

    /// A `swift test` that printed no closing count at all still closes on the line, saying that is what happened.
    ///
    /// A gate cannot tell a missing line from a binary older than the line, so absence is not an answer: a run whose build failed before the tests started says so here, which is also the one case the openings cannot cover.
    ///
    /// **And it says the right one of the three reasons.** Nothing opened, so nothing died — a clause asserting a death here would be false of the commonest shape that reaches it, and the openings are what tell the two apart.
    @Test
    func aRunThatPrintedNoCountAtAllStillCarriesTheLine() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(line: "/Users/dev/Depot/Sources/Depot/Thing.swift:3:14: error: cannot find 'nope' in scope")
        let report = filter.finish(exitCode: 1)
        #expect(report.testProcessOpenings == 0)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(line == "totals: ✘ failed · nothing to display, since no test process started")
        #expect(!line.contains("died"))
    }

    /// A run that opened, closed properly, and printed only a vestigial counter is the third shape, and it is neither of the other two.
    ///
    /// `Executed 0 tests, with 0 failures` is excluded from the display filter, so nothing survives it — but the process did close, so the reachability clause stays silent and no death can be claimed. Said wrongly, this reads as a process dying on a run where every process that opened also closed.
    ///
    /// The head is the verdict's own: a vestigial counter states no result, so there is no verdict in the log to take a word from, and the head says that rather than inventing one. Both halves of the line are about what was *not* there, and neither borrows the other's words.
    @Test
    func aRunWhoseOnlyCountWasVestigialSaysThatRatherThanClaimingADeath() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(line: "Test Suite 'All tests' started at 2026-09-19 09:12:58.236")
        filter.consume(line: "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds")
        let report = filter.finish(exitCode: 0)
        #expect(report.testProcessOpenings == report.testProcessClosings)
        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line == "totals: ⚠ no verdict in the log · nothing to display, since every closing count printed was vestigial")
        #expect(!line.contains("died"))
    }

    /// The token is anchored because a listed failure's own message can carry it — a real capture, not a hand-written line.
    ///
    /// `Fixtures/RunOutput/swift-test-quoted-totals.txt` is a `swift test` whose second `@Test` fails by comparing a string against a passing answer's closing line, so the rendered answer holds `totals:` twice: once inside the failure it lists, once as the line it closes on. Only the second begins a line — an unanchored `grep totals:` would match the first, and the first says `✔ passed` over a run that failed.
    @Test
    func theTokenIsAnchoredBecauseAFailureCanQuoteIt() throws {
        let report = try TestSources.runReport("swift-test-quoted-totals", invokedAs: ["swift", "test"], exitCode: 1)
        let answer = Self.answer(report, exitCode: 1)

        // Several lines of the answer carry the token; exactly one of them begins with it.
        let carrying = answer.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains("totals:") }
        #expect(carrying.count > 1)
        #expect(carrying.filter { $0.hasPrefix("totals:") }.count == 1)

        let line = try #require(Self.totalsLine(of: answer))
        #expect(line == "totals: ✘ failed · Swift Testing 2 tests in 1 suite, 2 failures")
    }

    /// The clause is owed even when the *only* process that opened is the XCTest one and the process that never closed is the Swift Testing helper — the crash probe's own shape: the helper opens on `Test run started.`, the XCTest harness never gets to its own `Executed …` because it dies first, and the helper closes its own tally regardless.
    ///
    /// Before the fix, `testProcessOpenings` counted only the XCTest opening (1) and the closing count taken was the greater of the two tallies (1, the helper's own) rather than their sum — so the two agreed and this clause never printed at all over a bundle that opened, crashed, and stated no XCTest count.
    @Test
    func aCrashedXCTestHalfStillOwesTheClauseEvenWhenTheHelperClosesItsOwnTally() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "◇ Test run started.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)

        #expect(report.testProcessOpenings == 2)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))
        #expect(line.contains("1 of 2 test processes printed a closing count"))
        #expect(line.contains("Swift Testing 1 test in 0 suites"))
    }

    /// The mirror of the case above: the process that closes is the XCTest one, on a counter that states nothing, and the process that never closes is the Swift Testing helper — a single `@Test` that calls `fatalError`.
    ///
    /// Before the false-denominator fix this read `totals: ✘ failed — 0 of 1 test process printed a closing count · no test process printed a closing count`: a false denominator, since the XCTest counter — vestigial, so never shown — did print, and two clauses said the same thing. Fixed, the anomaly names the true count, but the second clause still borrowed the first's own words — `no test process printed a closing count` read as a restatement of `1 of 2 test processes printed a closing count` rather than a different claim about a different population. The display clause now says what it means on its own terms, so the two no longer share a phrase for two different counts.
    @Test
    func aCrashedSwiftTestingHelperNeverFalselyReadsAsNoProcessClosing() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "◇ Test run started.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 1)))

        #expect(!line.contains("0 of 1 test process printed a closing count"))
        #expect(line.contains("1 of 2 test processes printed a closing count"))
        #expect(line.contains("nothing to display, since a process died before printing anything worth showing"))
        // The two clauses count different populations, so neither borrows the other's words.
        #expect(!line.contains("no test process printed a closing count"))
        // Not the same claim twice: exactly one clause after the dash, and exactly one after the final `·`.
        #expect(line.components(separatedBy: " — ").count == 2)
        #expect(line.components(separatedBy: " · ").count == 2)
    }

    /// `--parallel` prints no XCTest opening or closing count for the tests it actually runs in parallel, so the line says so rather than reading a Swift Testing tally of zero as the whole run.
    @Test
    func aParallelRunNamesTheLimitationRatherThanACountOfNothing() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test", "--parallel"])
        for line in [
            "[1/4] Testing GizmoTests.GizmoTests/testOne",
            "◇ Test run started.",
            "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))

        #expect(line.hasPrefix("totals: ⚠ passed —"))
        #expect(line.contains("run with --parallel"))
        #expect(line.contains("Swift Testing 0 tests in 0 suites"))
    }

    /// A pass whose count answers for fewer processes than opened is worded `incomplete` rather than `passed` — reachable now that both processes' openings and closings are counted, where before the missing XCTest half was invisible to the mechanism entirely.
    @Test
    func aPassWithAnUnheardProcessReadsAsIncompleteNotPassed() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "◇ Test run started.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        #expect(report.verdict?.state == .succeeded)

        let line = try #require(Self.totalsLine(of: Self.answer(report, exitCode: 0)))
        #expect(line.hasPrefix("totals: ⚠ incomplete —"))
        #expect(!line.contains("passed"))
    }

    /// `swift build` owes no closing count, and `swift test` always owes one: the line is the test contract's, and the pair is what says the contract is being read rather than the token being printed everywhere or nowhere.
    @Test
    func aBuildOwesNoTotalsLineWhileATestRunAlwaysCarriesOne() throws {
        var build = RunOutputFilter(invokedAs: ["swift", "build"])
        build.consume(line: "Build complete! (0.23 secs)")
        let buildAnswer = RunReportRenderer(kind: .swiftBuild, workingDirectory: Self.workingDirectory)
            .render(build.finish(exitCode: 0), exitCode: 0, logURL: nil)

        #expect(!buildAnswer.contains("totals:"))

        var test = RunOutputFilter(invokedAs: ["swift", "test"])
        test.consume(line: "Build complete! (0.23 secs)")
        test.consume(line: "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.")
        let testAnswer = Self.answer(test.finish(exitCode: 0), exitCode: 0)

        #expect(try #require(Self.totalsLine(of: testAnswer)) == "totals: ✔ passed · Swift Testing 29 tests in 4 suites")
    }

    /// `xcodebuild test` owes `.declares` its own `** TEST … **` stamp rather than `.runTally`'s, but it runs the same Swift Testing process `swift test` does — so a red run over a large suite must carry this line too, exactly as the equivalent green run already does, rather than leaving a reader to find the tally by grepping the raw log for `Test run with`.
    @Test
    func anXcodebuildTestRunCarriesTheLineWhicheverWayItEnds() throws {
        let invocation = ["xcodebuild", "test-without-building"]
        let passing = try TestSources.runReport("xcodebuild-test-execute-success", invokedAs: invocation, exitCode: 0)
        let passingAnswer = RunReportRenderer(kind: .xcodebuild, workingDirectory: Self.workingDirectory)
            .render(passing, exitCode: 0, logURL: nil)
        #expect(try #require(Self.totalsLine(of: passingAnswer)) == "totals: ✔ passed · Swift Testing 2658 tests in 290 suites")

        let failing = try TestSources.runReport("xcodebuild-test-execute-failure-environmental", invokedAs: invocation, exitCode: 65)
        let failingAnswer = RunReportRenderer(kind: .xcodebuild, workingDirectory: Self.workingDirectory)
            .render(failing, exitCode: 65, logURL: nil)
        #expect(try #require(Self.totalsLine(of: failingAnswer)) == "totals: ✘ failed · Swift Testing 2658 tests in 290 suites, 666 failures")
    }
}
