//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Where a site sits in the inheritance clause of the type or extension the scanner has just entered.
///
/// Swift resolves the names an inheritance clause writes from outside the type it declares, so `class Sub: Log.Item { typealias Log = Other }` inherits the `Item` the outer `Log` names: the type's own members, typealiases and nested types are not in scope there, though its generic parameters are.
struct InheritanceClauseScope {
    /// Whether `node` is written in the inheritance clause of a struct, class, enum, actor or extension, whose own scope it is not in.
    static func isInOwnClause(_ node: some SyntaxProtocol) -> Bool {
        for ancestor in sequence(first: Syntax(node), next: \.parent) {
            guard let clause = ancestor.as(InheritanceClauseSyntax.self) else {
                if ancestor.is(MemberBlockSyntax.self) || ancestor.is(CodeBlockSyntax.self) {
                    return false
                }
                continue
            }
            guard let parent = clause.parent else { return false }
            return parent.is(StructDeclSyntax.self) || parent.is(ClassDeclSyntax.self) || parent.is(EnumDeclSyntax.self)
                || parent.is(ActorDeclSyntax.self) || parent.is(ExtensionDeclSyntax.self)
        }
        return false
    }
}
