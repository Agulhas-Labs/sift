//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// A function's name written on nothing, with no call and no labels, where a function passed by name is written.
struct BareFunctionReference {
    /// Whether a name written on nothing is in a value's place — an argument, an element, a binding's or a `return`'s value: `map(f)`, `[f]`, `let g = f`, `return f` — and no local binding or parameter before it spells it.
    static func isHandedOn(_ node: DeclReferenceExprSyntax) -> Bool {
        guard let parent = node.parent, !parent.is(MemberAccessExprSyntax.self) else { return false }
        let inValuePlace = parent.is(LabeledExprSyntax.self) || parent.is(ArrayElementSyntax.self) || parent.is(InitializerClauseSyntax.self) || parent.is(ReturnStmtSyntax.self)
        return inValuePlace && !CallSiteScanner.LocalBindingShadow.hides(node.baseName.text, before: node)
    }
}
