//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The one generator for a call expression's base name.
///
/// Both body-shape matching (`calls:`) and the syntactic call-site fallback ask the same question of the same node, and an answer that differed between them would make `search calls:refresh` and `where refresh` disagree about the same line of code.
struct CalleeName {
    /// `save` from `save(x)` and `store.save(x)`, `Task` from `Task { }`, the base from `Foo<Bar>()`; `nil` when the callee is an expression with no name of its own (a closure literal invoked in place, a subscript result).
    static func base(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return SymbolNaming.name(of: reference.baseName)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return SymbolNaming.name(of: member.declName.baseName)
        }
        if let generic = expression.as(GenericSpecializationExprSyntax.self) {
            return base(of: generic.expression)
        }
        return nil
    }
}
