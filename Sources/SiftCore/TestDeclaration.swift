//
// Copyright © Agulhas Labs
//

/// One test as the index found it: what a runner selects, plus where it is written.
///
/// The two halves are separate because they answer to different readers. `TestSymbol` is what goes in a `-only-testing:` argument and so must be identical for two references into the same test; the path and line are for a human going to look, and must not make one test into two.
struct TestDeclaration {
    let symbol: TestSymbol
    let path: String
    let line: Int
    /// The innermost type nested in the named suite that holds the reference and is no suite, when the reference was rolled up to the suite from inside one.
    ///
    /// A route onward rather than a test: another suite builds that type, through an initialiser or under its suite's qualified name, without touching the member the reference sits in, so the walk follows the type and its initialisers as well as that member.
    var helperType: SymbolRow?
}
