//
// Copyright © Agulhas Labs
//

import Foundation

/// One name a working-tree walk scans for: the base name a site spells, the module declaring it, and the kind of declaration it names, which decides the shape of the sites that count.
struct AffectedNameSeed: Hashable, Sendable {
    let name: String
    let module: String
    let kind: SymbolKind

    /// The shape a call site of this seed takes: a type, a typealias or an associated type is reached wherever its name is written as one, and anything else as `where` scans a declaration of its kind, a function by a call or by being named unapplied.
    ///
    /// A function's bare name with no call and no labels, `x.gate`, is no site of it here, as `where` counts it beside its list rather than in it: the walk drops it (`AffectedRenderer.sites`), since it is far more often a same-named property of another type than a function handed on unapplied, and on a rename it carried the walk across most of a target.
    var shape: CallSiteScanner.SiteShape {
        if kind.isTypeDeclaration || kind == .extensionKind || kind == .typealiasKind || kind == .associatedType {
            return .typeUse
        }
        return .of(kind, sharing: nil)
    }

    /// The seed for an indexed declaration as a call site spells it: an initializer is called through its type, so it is the type's name.
    static func callSite(of row: SymbolRow, in store: IndexStore) throws -> AffectedNameSeed {
        guard row.kind == .initializer, let type = try store.parentChain(of: row).last else {
            return AffectedNameSeed(name: row.baseName, module: row.module, kind: row.kind)
        }
        return AffectedNameSeed(name: DeclaredTypeName.last(ofPath: type.name), module: row.module, kind: .initializer)
    }

    /// Whether a declaration's base name is something an identifier token could ever equal.
    ///
    /// Asked of every name that enters a walk's frontier, at every hop, not only of the seed set. The two paths carry the same kind of thing (a declaration's base name) and pay the same price for an operator: a name the visitor can never match, whose substring pre-filter matches almost everything.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        return first.isLetter || first == "_"
    }
}
