//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Where a site sits in the body of a protocol that declares an associated type of the name the site writes.
///
/// Swift looks a bare type name up in the protocol around it before anything outside, so `func take(_ x: Item)` in a protocol declaring `associatedtype Item` writes that associated type and never a same-named type declared elsewhere. Only a declaration the protocol's own body makes outside any `#if` proves it: one under `#if`, one an inherited protocol or an extension makes, and a site in the protocol's inheritance or where clause leave the line a use. So does an attribute, which names the module-scoped type (`@Item func f()`), never the associated type.
struct ProtocolBodyScope {
    /// `site`, a type use writing `name` at `node`, marked as meaning the protocol's own associated type where it writes the name bare in such a body.
    static func marking(_ site: SyntacticCallSite, writing name: String, at node: some SyntaxProtocol) -> SyntacticCallSite {
        var marked = site
        marked.meansOwnAssociatedType = site.qualifier == nil && declaresAssociatedType(name, around: node)
        return marked
    }

    /// Whether `node` is written in the body of a protocol that declares `associatedtype` of `name` among its own members, outside any `#if`.
    static func declaresAssociatedType(_ name: String, around node: some SyntaxProtocol) -> Bool {
        for ancestor in sequence(first: Syntax(node), next: \.parent) {
            if ancestor.is(CodeBlockSyntax.self) || ancestor.is(ClosureExprSyntax.self) || ancestor.is(AttributeSyntax.self) {
                return false
            }
            guard let body = ancestor.as(MemberBlockSyntax.self) else { continue }
            guard body.parent?.is(ProtocolDeclSyntax.self) == true else { return false }
            return body.members.contains { member in
                member.decl.as(AssociatedTypeDeclSyntax.self).map { ($0.name.identifier?.name ?? $0.name.text) == name } ?? false
            }
        }
        return false
    }
}
