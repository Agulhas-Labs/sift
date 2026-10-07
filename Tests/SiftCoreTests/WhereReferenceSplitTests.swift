//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers how a type's use sites are split for the usage verdict, over rows and paths directly rather than a built store.
///
/// A store occurrence in a file the index never held — a build-generated source — cannot be made by a SwiftPM fixture whose every source the index reads, and the split is a pure function of the paths, their rows and the deletion ledger, so it is driven here without one.
struct WhereReferenceSplitTests {
    /// Imports per repo-relative path for the paths the index holds a row for; any other path has none.
    private static let rows: [String: [String]] = [
        "Sources/Lib/Assembly.swift": ["Foundation"],
        "Tests/LibTests/WidgetTests.swift": ["Testing", "Lib"],
    ]

    /// A path with no row that the ledger never saw go is named as never held, never as a deletion that did not happen.
    @Test
    func aPathTheIndexNeverHeldIsNamedAsNeverHeld() {
        let split = WhereRenderer.usageSplit(
            sitesByPath: [("Sources/Lib/Assembly.swift", 2), ("Derived/Sources/Generated.swift", 3)],
            deleted: []
        ) { Self.rows[$0] }

        #expect(split == WhereRenderer.UsageSplit(production: 2, tests: 0, deleted: 0, neverHeld: 3))
        #expect(split.tally == ["2 production", "0 tests", "3 in files the index never held"])
    }

    /// A path with no row that the ledger recorded leaving the tree is named as deleted, and kept apart from one never held.
    @Test
    func aPathTheLedgerSawDeletedIsNamedAsDeleted() {
        let split = WhereRenderer.usageSplit(
            sitesByPath: [
                ("Tests/LibTests/WidgetTests.swift", 1),
                ("Sources/Lib/Removed.swift", 4),
                ("Derived/Sources/Generated.swift", 1),
            ],
            deleted: ["Sources/Lib/Removed.swift"]
        ) { Self.rows[$0] }

        #expect(split == WhereRenderer.UsageSplit(production: 0, tests: 1, deleted: 4, neverHeld: 1))
        #expect(split.tally == ["0 production", "1 test", "4 in files deleted from the tree", "1 in files the index never held"])
    }

    /// A path the ledger once recorded but the index holds a row for again is split by its imports, the row being the fresher fact.
    @Test
    func aPathWithARowIsSplitByItsImportsWhateverTheLedgerSays() {
        let split = WhereRenderer.usageSplit(
            sitesByPath: [("Sources/Lib/Assembly.swift", 2)],
            deleted: ["Sources/Lib/Assembly.swift"]
        ) { Self.rows[$0] }

        #expect(split.tally == ["2 production", "0 tests"])
    }
}
