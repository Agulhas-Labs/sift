//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers tests whose result lines were lost under suites and runs that passed, as the analyse answer and the arithmetic read them, and the runs that account for nothing.
@Suite(.temporaryDirectories)
struct RunReconciliationLostLinesTests {
    /// Two suites each declare the same function, both started and neither printed a result line, and both suites and the run passed: the group lost its result lines, and nothing is missing.
    @Test
    func aGroupWhoseStartsCoverItsShortfallUnderPassingSuitesLostItsResultLines() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test countIsOne() started.",
            "◇ Test countIsOne() started.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Suite BinLabelTests passed after 0.002 seconds.",
            "✔ Test run with 2 tests in 2 suites passed after 0.002 seconds.",
        ])

        #expect(reconciliation.counts == ReconciliationCounts(expected: 2, ran: 0, passed: 0, failed: 0, skipped: 0, missing: 0, duplicated: 0, linesLost: 2))
        #expect(reconciliation.shortfalls.isEmpty)
        #expect(reconciliation.isGreen)
        let answer = RunReconciliationRenderer().render(reconciliation)
        #expect(answer.contains("  countIsOne: 2 of these 2 lost their result lines"))
        #expect(answer.contains("lines lost 2"))
    }

    /// The same group under a suite that failed is a shortfall as before: a failing suite accounts for nothing.
    @Test
    func aGroupUnderAFailingSuiteIsStillAShortfall() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test countIsOne() started.",
            "◇ Test countIsOne() started.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✘ Suite BinLabelTests failed after 0.002 seconds with 1 issue.",
            "✔ Test run with 2 tests in 2 suites passed after 0.002 seconds.",
        ])

        #expect(reconciliation.counts.missing == 2)
        #expect(reconciliation.lostByCount.isEmpty)
        #expect(!reconciliation.isGreen)
    }

    /// The group's starts sit in a run that crashed, after another run passed with both suites' pass lines: the crashed run accounts for nothing, so the group is a shortfall.
    @Test
    func aGroupStartedInARunThatPrintedNoSummaryIsStillAShortfall() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Suite BinLabelTests passed after 0.002 seconds.",
            "✔ Test run with 0 tests in 2 suites passed after 0.002 seconds.",
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "◇ Test countIsOne() started.",
            "Fatal error: boom",
        ])

        #expect(reconciliation.counts.missing == 2)
        #expect(reconciliation.lostByCount.isEmpty)
        #expect(!reconciliation.isGreen)
    }

    /// Run one passed with its summary, and run two printed the test's suite passing and then crashed before its summary: nothing accounts for the test, so it was never reported, and the answer is red.
    @Test
    func aTestStartedInARunThatPrintedNoSummaryIsNeverReported() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.",
            "◇ Test run started.",
            "◇ Test dimLampWorks() started.",
            "✔ Suite LampTests passed after 0.002 seconds.",
            "◇ Test countIsOne() started.",
            "Fatal error: boom",
        ], files: Self.threeSuites)

        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/Depot/countIsOne()", "GizmoTests/LampTests/dimLampWorks()"])
        #expect(reconciliation.counts.linesLost == 0)
        #expect(!reconciliation.isGreen)
        #expect(RunReconciliationRenderer().render(reconciliation).contains("✘ sift test --analyse --against — 2 missing"))
    }

    /// Another run printed a pass line for a suite of the same innermost name and a passing summary, and the test's own run crashed: that pass line is not its suite's, so the test was never reported.
    @Test
    func aSuiteOfTheSameNameInAnotherRunAccountsForNothing() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test dimLampWorks() started.",
            "✔ Test dimLampWorks() passed after 0.001 seconds.",
            "✔ Suite Inner passed after 0.002 seconds.",
            "✔ Suite Orchard passed after 0.002 seconds.",
            "✔ Test run with 1 test in 2 suites passed after 0.002 seconds.",
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "Fatal error: boom",
        ], files: Self.twoNestedSuites)

        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/Depot.Inner/countIsOne()"])
        #expect(!reconciliation.isGreen)
    }

    /// A nested suite prints its innermost name alone, so a test of it that started with no result line, in a run that printed that pass line and a passing summary, lost its result line.
    @Test
    func aNestedSuitesTestIsJudgedByTheInnermostNameItsSuitePrints() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Suite Inner passed after 0.002 seconds.",
            "✔ Suite Depot passed after 0.002 seconds.",
            "✔ Test run with 2 tests in 2 suites passed after 0.002 seconds.",
        ], files: Self.oneNestedSuite)

        #expect(reconciliation.lost.map(\.enumerated) == ["GizmoTests/Depot.Inner/countIsOne()"])
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.isGreen)
    }

    /// A test that cancelled itself ended, so its start is not unfinished: it is counted as skipped, never as a lost result line.
    @Test
    func aCancelledTestIsSkippedNeverLost() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "➜ Test countIsOne() was cancelled after 0.001 seconds: \"probe\"",
            "✔ Suite Depot passed after 0.002 seconds.",
            "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.",
        ], files: Self.threeSuites)

        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.counts.skipped == 1)
        #expect(!reconciliation.missing.map(\.enumerated).contains("GizmoTests/Depot/countIsOne()"))
    }

    /// A line naming the test in a wording the reader does not know may be its ending, so the run does not account for that test, which stays never reported.
    @Test
    func aTestThatPrintedAnUnreadLineIsNeverLost() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "➜ Test countIsOne() was halted after 0.001 seconds.",
            "✔ Suite Depot passed after 0.002 seconds.",
            "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.",
        ], files: Self.threeSuites)

        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.missing.map(\.enumerated).contains("GizmoTests/Depot/countIsOne()"))
    }

    /// A test that recorded known issues and then lost its result line is lost, not never reported: a known issue is no failure, and its suite and run passed.
    @Test
    func aTestThatRecordedAKnownIssueCanStillLoseItsLine() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "━ Test countIsOne() recorded a known issue at Depot.swift:13:44: Issue recorded",
            "✔ Suite Depot passed after 0.002 seconds with 1 known issue.",
            "━ Test run with 1 test in 1 suite passed after 0.002 seconds with 1 known issue.",
        ], files: Self.threeSuites)

        #expect(reconciliation.lost.map(\.enumerated) == ["GizmoTests/Depot/countIsOne()"])
        #expect(!reconciliation.missing.map(\.enumerated).contains("GizmoTests/Depot/countIsOne()"))
    }

    /// A run crashed before its summary and the next run's start line was lost, so the two read as one run that started more tests than its summary counts: that summary cannot speak for the crashed test, which stays never reported.
    @Test
    func aRunThatStartedMoreTestsThanItsSummaryCountsVouchesForNothing() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "Fatal error: boom",
            "◇ Test dimLampWorks() started.",
            "✔ Test dimLampWorks() passed after 0.001 seconds.",
            "✔ Suite Inner passed after 0.002 seconds.",
            "✔ Suite Orchard passed after 0.002 seconds.",
            "✔ Test run with 1 test in 2 suites passed after 0.002 seconds.",
        ], files: Self.twoNestedSuites)

        #expect(reconciliation.lost.isEmpty)
        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/Depot.Inner/countIsOne()"])
        #expect(!reconciliation.isGreen)
    }

    /// The green headline counts the tests whose result lines were lost beside the ones that passed, never among them.
    @Test
    func theGreenHeadlineAddsTheLostTestsToThePassedOnes() throws {
        let reconciliation = try Self.reconcile([
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Suite Inner passed after 0.002 seconds.",
            "✔ Test run with 2 tests in 2 suites passed after 0.002 seconds.",
        ], files: Self.oneNestedSuite)
        let answer = RunReconciliationRenderer().render(reconciliation)

        #expect(answer.contains("✔ sift test --analyse --against — 1 tests passed and 1 more by their suite and run summaries, every expected test accounted for"))
    }
}

private extension RunReconciliationLostLinesTests {
    /// Two suites in one target, each declaring a test of the same name.
    static var files: [(path: String, source: String)] {
        [
            ("GizmoTests/PalletTests.swift", "import Testing\n\nstruct PalletTests {\n    @Test func countIsOne() {}\n}\n"),
            ("GizmoTests/BinLabelTests.swift", "import Testing\n\nstruct BinLabelTests {\n    @Test func countIsOne() {}\n}\n"),
        ]
    }

    /// Three suites, each declaring one test of its own.
    static var threeSuites: [(path: String, source: String)] {
        [
            ("GizmoTests/PalletTests.swift", "import Testing\n\nstruct PalletTests {\n    @Test func anOrdinaryPass() {}\n}\n"),
            ("GizmoTests/LampTests.swift", "import Testing\n\nstruct LampTests {\n    @Test func dimLampWorks() {}\n}\n"),
            ("GizmoTests/Depot.swift", "import Testing\n\nstruct Depot {\n    @Test func countIsOne() {}\n}\n"),
        ]
    }

    /// Two nested suites whose innermost types share one name, under outer types of different names.
    static var twoNestedSuites: [(path: String, source: String)] {
        [
            ("GizmoTests/Depot.swift", "import Testing\n\nenum Depot {\n    struct Inner {\n        @Test func countIsOne() {}\n    }\n}\n"),
            ("GizmoTests/Orchard.swift", "import Testing\n\nenum Orchard {\n    struct Inner {\n        @Test func dimLampWorks() {}\n    }\n}\n"),
        ]
    }

    /// One nested suite declaring two tests.
    static var oneNestedSuite: [(path: String, source: String)] {
        [("GizmoTests/Depot.swift", "import Testing\n\nenum Depot {\n    struct Inner {\n        @Test func countIsOne() {}\n        @Test func anOrdinaryPass() {}\n    }\n}\n")]
    }

    /// What the reconciler makes of `lines` over `files`, inside a container that admits their one target.
    static func reconcile(_ lines: [String], files: [(path: String, source: String)] = files) throws -> RunReconciliation {
        let root = try TemporaryDirectory.make("reconciliation-lost")
        let store = try TestSources.makeStore()
        try store.replaceFiles(files.map { try TestSources.parsed($0.source, path: $0.path, in: root) }) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, false)
        }
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return try RunReconciler.reconcile(
            inventory: TestInventory.read(store: store, repositoryRoot: root),
            outcomes: outcomes,
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
    }
}
