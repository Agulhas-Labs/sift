//
// Copyright © Agulhas Labs
//

/// One function whose body opens with a statement that decides whether it runs, located well enough to join back to an index row.
///
/// Only the first statement counts. A test that calls `XCTFail` after twenty lines of setup is a test that failed, and folding the two together would hide real failures behind a convention.
struct TestBodyOpening: Sendable, Hashable {
    /// The function's labeled name, spelled as `SymbolRow.name` spells it.
    let name: String
    /// The declaration's first line, attributes included — an index row's line is this one or the `func` keyword's, so the join is by containment rather than by equality.
    let startLine: Int
    let endLine: Int
    /// What the first statement of the body says about whether the test runs.
    let disposition: DeclaredTest.Disposition
}
