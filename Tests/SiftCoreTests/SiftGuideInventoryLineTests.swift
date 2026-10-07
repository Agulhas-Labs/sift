//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the agent guide's pointer to the `inventory:` line as the discovered-against-executed answer, and that the line it names is the one `sift run` prints.
struct SiftGuideInventoryLineTests {
    private static var repository: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
    }

    /// `Sift.md` with line breaks folded, so a sentence reads the same wherever the wrap fell.
    private static func guide() throws -> String {
        try String(contentsOf: repository.appendingPathComponent("Sift.md"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The guide names the line, the hand-rolled count it replaces, the one run that prints it, and the not-checked outcome as a separate one.
    @Test
    func theGuideNamesTheInventoryLineAsTheDiscoveredAgainstExecutedAnswer() throws {
        let guide = try Self.guide()

        #expect(guide.contains("`inventory: N declared, M reported`, not `swift test list | grep -c`, is discovered vs run"))
        #expect(guide.contains("only an unfiltered, serial root-package `swift test` prints it"))
        #expect(guide.contains("(`inventory: not checked — …` is another outcome)"))
    }

    /// The two lines the guide quotes are spelt as the check renders them, for a run that adds up and for one that could not be checked, so a change to either wording has to reach the guide too.
    @Test
    func theGuideQuotesBothLinesAsTheCheckRendersThem() throws {
        let reconciliation = RunReconciliation(
            counts: ReconciliationCounts(expected: 3, ran: 3, passed: 3, failed: 0, skipped: 0, missing: 0, duplicated: 0),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log"),
            iterations: 1,
            missing: [],
            shortfalls: [],
            duplicated: [],
            failed: [],
            excluded: [],
            undecided: [],
            unclaimed: [],
            outsideScope: [],
            notes: []
        )

        let reconciled = RunInventoryCheck.reconciled(reconciliation).lines
        let skipped = RunInventoryCheck.skipped("no index").lines
        let guide = try Self.guide()

        #expect(reconciled == ["inventory: 3 declared, 3 reported"])
        #expect(skipped == ["inventory: not checked — no index"])
        let quotedReconciled = reconciled.first?.replacingOccurrences(of: "3 declared, 3 reported", with: "N declared, M reported") ?? ""
        let quotedSkipped = skipped.first?.replacingOccurrences(of: "no index", with: "…") ?? ""
        #expect(guide.contains("`\(quotedReconciled)`"))
        #expect(guide.contains("`\(quotedSkipped)`"))
    }
}
