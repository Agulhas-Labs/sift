//
// Copyright © Agulhas Labs
//

import Foundation

/// The words a store-backed `callers of` heading adds when other types declare the member's name.
struct WhereCallersResolvedClause {
    let store: IndexStore

    /// The clause a store-backed callers heading carries when other declarations share the member's base name: the sites are resolved to this one declaration, so those declarations' calls are not among them.
    ///
    /// Counts the same-named declarations outside this declaration's own enclosing type, the count ``DigestMemberMissAnswer/elsewhereClause(baseName:elsewhere:)`` words for a missed member. Never asked of the no-store path, whose sites are name matches.
    ///
    /// - Parameter bare: Whether the query was the bare base name, which already is the list the clause would point at, so the pointer is left off.
    func clause(for row: SymbolRow, bare: Bool = false) throws -> String? {
        // Every type declares an `init`, so the name rules nothing out.
        guard row.kind != .initializer else { return nil }
        let baseName = QualifiedPath.baseName(of: row.name)
        let ownChain = try QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name))
        var elsewhere = 0
        for other in try store.symbols(named: baseName) where other.id != row.id {
            if try QualifiedPath.flattened(chain: store.parentChain(of: other).map(\.name)) != ownChain {
                elsewhere += 1
            }
        }
        guard elsewhere > 0 else { return nil }
        let counted = DigestMemberMissAnswer.elsewhereClause(baseName: baseName, elsewhere: elsewhere)
        let pointer = bare ? "" : "; where \(baseName) lists them"
        let declared = counted.replacingOccurrences(of: " — where \(baseName) lists them", with: "")
        return "resolved to this declaration — \(declared), not counted here\(pointer)"
    }
}
