//
// Copyright © Agulhas Labs
//

/// A declaration's line range on one side of a diff, in the same `:start-end` spelling `SymbolRow.rangeDescription` prints.
///
/// Repeated here rather than shared, because a `ParsedSymbol` diff-side reading has no `SymbolRow` to hang the same extension off.
struct DeclarationRange: Sendable, Equatable {
    let line: Int
    let endLine: Int

    var described: String {
        line == endLine ? ":\(line)" : ":\(line)-\(endLine)"
    }
}
