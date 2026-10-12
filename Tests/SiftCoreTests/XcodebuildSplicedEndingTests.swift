//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a Swift Testing ending `xcodebuild` printed with other output spliced in after the test's name: a fragment glued in front of `passed`, or a whole log line with the ending's words pushed onto the next line.
///
/// Both shapes are from a real `xcodebuild test` of a package's `-Package` scheme whose summary passed 4026 tests: before they were read, the two tests they ended were listed as never reported.
@Suite(.temporaryDirectories)
struct XcodebuildSplicedEndingTests {
    /// A line from another stream, spliced in whole.
    private static var logLine: String {
        "2026-10-12 12:59:21.353130+0100 xctest[61:55] [Depot] Reloading the catalogue failed: error 0.)"
    }

    /// A fragment glued between the name and `passed` is read past, and the test passed.
    @Test
    func aFragmentBetweenTheNameAndItsEndingIsReadPast() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() Barrierpassed after 15.504 seconds.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .passed)
        #expect(outcomes.attempts["countIsOne()"]?.first?.seconds == 15.504)
    }

    /// A failing ending with a fragment in front of it is read as the failure it is.
    @Test
    func aFailingEndingBehindAFragmentIsAFailure() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() Barrier failed after 0.002 seconds with 1 issue.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .failed)
    }

    /// A whole log line spliced in after the name pushes the ending's words onto the next line, and the two are read as the one ending.
    @Test
    func anEndingPushedOntoTheNextLineIsReadWithItsHead() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() " + Self.logLine,
            "passed after 198.531 seconds.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .passed)
        #expect(outcomes.attempts["countIsOne()"]?.first?.seconds == 198.531)
    }

    /// The ending's words count only on the line straight after the spliced head: one line later they are another line's.
    @Test
    func anEndingTwoLinesLaterCountsForNothing() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() " + Self.logLine,
            Self.logLine,
            "passed after 198.531 seconds.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == nil)
    }

    /// Both shapes, as `sift run -- xcodebuild test` reads the console, end their tests and leave nothing never reported.
    @Test
    func theRunReportReadsBothShapes() throws {
        var filter = RunOutputFilter(invokedAs: ["xcodebuild", "test", "-scheme", "Gizmo-Package"])
        for line in Self.splicedRun {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        #expect(report.testOutcomes.lastEndings["countIsOne()"] == .passed)
        #expect(report.testOutcomes.lastEndings["dimLampWorks()"] == .passed)
        let reconciliation = try Self.reconcile(Self.splicedRun)
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.counts.passed == 3)
    }

    /// A started test whose ending was spliced past reading lost its result line under a suite and run that passed, and is never called never reported.
    @Test
    func aStartedTestWhoseEndingCannotBeReadIsLostNotNeverReported() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() " + Self.logLine,
            Self.logLine,
            "✔ Suite Depot passed after 0.002 seconds.",
            "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.",
        ])

        #expect(reconciliation.lost.map(\.enumerated) == ["GizmoTests/Depot/countIsOne()"])
        #expect(!reconciliation.missing.map(\.enumerated).contains("GizmoTests/Depot/countIsOne()"))
    }

    /// An issue whose message quotes another test's ending, for a test that never started, counts for neither test.
    @Test
    func aQuotedEndingInAnIssueCountsForNoTest() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() recorded an issue at Depot.swift:4:5: Expectation failed: \"✔ Test dimLampWorks() passed after 1 seconds.\"",
            "✘ Test countIsOne() recorded an issue at Depot.swift:5:5: Issue recorded: the pallet passed after 1 seconds.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == nil)
        #expect(outcomes.lastEndings["dimLampWorks()"] == nil)
    }

    /// A spliced ending for a test that never started, or that already ended, counts for nothing.
    @Test
    func aSplicedEndingCountsOnlyForAStartedTestWithNoEnding() {
        let outcomes = Self.outcomes([
            "✔ Test dimLampWorks() Barrierpassed after 1 seconds.",
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() failed after 0.002 seconds with 1 issue.",
            "✔ Test countIsOne() Barrierpassed after 1 seconds.",
            "✔ Test countIsOne() " + Self.logLine,
            "passed after 1 seconds.",
        ])

        #expect(outcomes.lastEndings["dimLampWorks()"] == nil)
        #expect(outcomes.lastEndings["countIsOne()"] == .failed)
        #expect(outcomes.attempts["countIsOne()"]?.count == 1)
    }

    /// A spliced log line that closes on an ending's wording of its own does not stand in for the framework's ending on the next line, which failed.
    @Test
    func aSplicedLineClosingOnAPassGivesWayToTheFailureOnTheNextLine() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() 2026-10-12 12:59:21.353 xctest[61:55] [Depot] subtask passed after 3 seconds.",
            "failed after 4 seconds with 1 issue.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .failed)
        #expect(outcomes.attempts["countIsOne()"] == [RunTestOutcomes.Attempt(ending: .failed, seconds: 4)])
        #expect(outcomes["countIsOne()"]?.passed == 0)
        #expect(outcomes["countIsOne()"]?.failed == 1)
    }

    /// An issue spliced in behind a fragment, whose message closes on an ending's wording, is no ending: the test's own failing line that follows is its one attempt.
    @Test
    func aSplicedIssueClosingOnAPassIsNoEnding() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() Barrierrecorded an issue at Depot.swift:5:5: Issue recorded: the pallet passed after 1 seconds.",
            "✘ Test countIsOne() failed after 0.002 seconds with 1 issue.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .failed)
        #expect(outcomes.attempts["countIsOne()"]?.count == 1)
        #expect(outcomes["countIsOne()"]?.passed == 0)
        #expect(outcomes["countIsOne()"]?.failed == 1)
    }

    /// A known issue spliced in behind a fragment is no ending either, whatever its message closes on.
    @Test
    func aSplicedKnownIssueClosingOnAFailureIsNoEnding() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() Barrierrecorded a known issue at Depot.swift:5:5: the pallet failed after 1 seconds with 1 issue.",
            "✔ Test countIsOne() passed after 0.002 seconds with 1 known issue.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .passed)
        #expect(outcomes.attempts["countIsOne()"]?.count == 1)
    }

    /// Where the line after a spliced line closing on an ending is no ending, the closing words stand.
    @Test
    func aSplicedLineClosingOnAPassStandsWhenNoEndingFollows() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() Barrierpassed after 15.504 seconds.",
            Self.logLine,
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .passed)
        #expect(outcomes.attempts["countIsOne()"] == [RunTestOutcomes.Attempt(ending: .passed, seconds: 15.504)])
    }

    /// The whole ending on the next line wins over a failing ending the spliced line closed on: the next line holds nothing but the framework's ending words, while the spliced line's closing words could be the spliced output's own, so a test the framework says passed is not counted failed on a log line's say-so.
    @Test
    func theEndingOnTheNextLineWinsOverAFailureTheSplicedLineClosedOn() {
        let outcomes = Self.outcomes([
            "◇ Test countIsOne() started.",
            "✘ Test countIsOne() 2026-10-12 12:59:21.353 xctest[61:55] [Depot] subtask failed after 1 seconds with 1 issue.",
            "passed after 2 seconds.",
        ])

        #expect(outcomes.lastEndings["countIsOne()"] == .passed)
        #expect(outcomes.attempts["countIsOne()"] == [RunTestOutcomes.Attempt(ending: .passed, seconds: 2)])
        #expect(outcomes["countIsOne()"]?.passed == 1)
        #expect(outcomes["countIsOne()"]?.failed == 0)
    }

    /// A run of three tests, one ending whole and one in each spliced shape, under passing suites and a passing summary.
    private static var splicedRun: [String] {
        [
            "◇ Test run started.",
            "◇ Test anOrdinaryPass() started.",
            "◇ Test countIsOne() started.",
            "◇ Test dimLampWorks() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Test countIsOne() Barrierpassed after 15.504 seconds.",
            "✔ Test dimLampWorks() " + logLine,
            "passed after 198.531 seconds.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Suite LampTests passed after 198.6 seconds.",
            "✔ Suite Depot passed after 15.6 seconds.",
            "✔ Test run with 3 tests in 3 suites passed after 198.6 seconds.",
        ]
    }

    /// What the reconciler makes of `lines` over three suites of one test each in the one target `GizmoTests`.
    private static func reconcile(_ lines: [String]) throws -> RunReconciliation {
        let root = try TemporaryDirectory.make("spliced-ending")
        let store = try TestSources.makeStore()
        let files = [
            ("GizmoTests/PalletTests.swift", "import Testing\n\nstruct PalletTests {\n    @Test func anOrdinaryPass() {}\n}\n"),
            ("GizmoTests/LampTests.swift", "import Testing\n\nstruct LampTests {\n    @Test func dimLampWorks() {}\n}\n"),
            ("GizmoTests/Depot.swift", "import Testing\n\nstruct Depot {\n    @Test func countIsOne() {}\n}\n"),
        ]
        try store.replaceFiles(files.map { try TestSources.parsed($0.1, path: $0.0, in: root) }) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, false)
        }
        return try RunReconciler.reconcile(
            inventory: TestInventory.read(store: store, repositoryRoot: root),
            outcomes: outcomes(lines),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
    }

    /// The outcomes read from `lines`.
    private static func outcomes(_ lines: [String]) -> RunTestOutcomes {
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return outcomes
    }
}
