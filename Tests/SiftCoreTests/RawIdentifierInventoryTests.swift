//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A swift-testing function written as a raw identifier carries no display-name literal, yet the runner prints its words in quotes, so the inventory has to join the ending on them.
@Suite(.temporaryDirectories)
struct RawIdentifierInventoryTests {
    private static var source: (path: String, source: String) {
        (
            "GizmoTests/PalletTests.swift",
            """
            import Testing

            struct PalletTests {
                @Test func `settles a slot`() {}
                @Test func `drains in order`(_ count: Int) {}
                @Test func `settle`() {}
            }
            """
        )
    }

    private static func reconcile(reporting lines: [String]) throws -> RunReconciliation {
        let root = try TemporaryDirectory.make("raw-identifier")
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source.source, path: source.path, in: root)
        try store.replaceFiles([parsed]) { _ in ("GizmoTests", false) }
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

    /// A green run of every test, the raw-identifier ones printed by their words and the backticked keyword by its function, reports every declared test and names none as never reported.
    @Test
    func aGreenRunOfRawIdentifierTestsReportsEveryDeclaredTest() throws {
        let reconciliation = try Self.reconcile(reporting: [
            "Test \"settles a slot\" started.", "Test \"settles a slot\" passed after 0.001 seconds.",
            "Test \"drains in order\" started.", "Test \"drains in order\" passed after 0.001 seconds.",
            "Test settle() started.", "Test settle() passed after 0.001 seconds.",
        ])

        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.counts.ran == 3)
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.isGreen)
    }

    /// The words are the join and nothing more: a raw-identifier test that never printed is still missing.
    @Test
    func aRawIdentifierTestThatNeverPrintedIsStillMissing() throws {
        let reconciliation = try Self.reconcile(reporting: [
            "Test \"settles a slot\" started.", "Test \"settles a slot\" passed after 0.001 seconds.",
            "Test settle() started.", "Test settle() passed after 0.001 seconds.",
        ])

        #expect(reconciliation.missing.count == 1)
        #expect(reconciliation.isGreen == false)
    }
}
