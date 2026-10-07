//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A skipped test is named on the inventory line rather than read as reported, and the plain `--analyse` answer spells a file-scope test as the run inventory does and keeps the tests an inactive `#if` hides out of its counts.
@Suite(.temporaryDirectories)
struct AnalyseInventoryGapTests {
    private static var source: String {
        """
        import Testing
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {}
        }

        @Test(.disabled("not yet")) func switchedOff() {}

        #if os(Linux)
        @Test func linuxOnly() {}
        #endif
        """
    }

    private static func store(in root: URL) throws -> IndexStore {
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: "Tests/GizmoTests/GizmoTests.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("GizmoTests", false) }
        return store
    }

    /// A green run whose runner printed a skip line for the disabled test: the line says one test was skipped and names it, where it used to count it among those reported.
    @Test
    func aSkippedTestIsNamedOnTheInventoryLine() throws {
        let root = try TemporaryDirectory.make("skipped-inventory")
        var outcomes = RunTestOutcomes()
        let lines = [
            "Test Case '-[GizmoTests.PalletTests testOne]' started.",
            "Test Case '-[GizmoTests.PalletTests testOne]' passed (0.001 seconds).",
            "◇ Test switchedOff() started.",
            "↩ Test switchedOff() skipped: \"not yet\"",
        ]
        for line in lines {
            outcomes.read(line)
        }
        let reconciliation = try RunReconciler.reconcile(
            inventory: TestInventory.read(store: Self.store(in: root), repositoryRoot: root),
            outcomes: outcomes,
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )

        #expect(reconciliation.counts.skipped == 1)
        #expect(reconciliation.skipped.map(\.enumerated) == ["GizmoTests/(file scope)/switchedOff()"])
        let line = try #require(RunInventoryCheck.reconciled(reconciliation).lines.first)
        #expect(line.contains("1 skipped by the runner, not run: GizmoTests/(file scope)/switchedOff()"))
    }

    private static func analysis(in root: URL) throws -> TestAnalysis {
        try TestAnalysis.of(
            inventory: TestInventory.read(store: store(in: root), repositoryRoot: root),
            survey: TestPlanSurvey(plans: [], unreadable: [])
        )
    }

    /// Plain `--analyse` names a file-scope test under `(file scope)` like the run inventory does, never with an empty type between two slashes.
    @Test
    func aFileScopeTestIsSpelledWithItsFileScopeType() throws {
        let root = try TemporaryDirectory.make("analyse-file-scope")
        let answer = try TestAnalysisRenderer().render(Self.analysis(in: root))

        #expect(answer.contains("GizmoTests/(file scope)/switchedOff()"))
        #expect(answer.contains("GizmoTests//") == false)
    }

    /// A test under an `#if` this platform does not compile is not in any count, and the answer names it apart.
    @Test
    func aCompiledOutTestIsLeftOutOfTheCountsAndNamedApart() throws {
        let root = try TemporaryDirectory.make("analyse-compiled-out")
        let analysis = try Self.analysis(in: root)

        #expect(analysis.counts.declared == 2)
        #expect(analysis.compiledOut.map(\.function) == ["linuxOnly()"])
        let answer = TestAnalysisRenderer().render(analysis)
        #expect(answer.contains("compiled out here (1)"))
        #expect(answer.contains("  GizmoTests/(file scope)/linuxOnly()"))
    }
}
