//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// What a call's receiver is written as, where the scan can tell the type it names without resolving anything.
enum CallReceiver: Sendable, Equatable {
    /// No receiver, or `self` or `Self`: the call is made on the types the site is written in.
    case enclosingSelf
    /// A type written by name, `U.m(x)` or `U(y).m(x)`, by its simple name, and whether that name may stand for a type the repository cannot show.
    ///
    /// The trailing name of a dotted path, `App.U` or `T.Shared`, may be a property rather than a type, and a name written in an extension may be the extended type's generic parameter, so either is another type only where the repository declares it.
    ///
    /// Whether the name is written behind a dot is carried apart: a qualifier the scan does not resolve may be a module's or a framework type's, whose type of the name is not the repository's.
    case type(String, mayBeUnseen: Bool, isQualified: Bool = false)

    /// The receiver of a call whose callee is `callee`, or `nil` where it is anything the scan cannot type — a variable, a chain, a leading-dot member.
    static func of(_ callee: ExprSyntax) -> CallReceiver? {
        if let generic = callee.as(GenericSpecializationExprSyntax.self) {
            return of(generic.expression)
        }
        if callee.is(DeclReferenceExprSyntax.self) {
            return .enclosingSelf
        }
        guard let base = callee.as(MemberAccessExprSyntax.self)?.base else { return nil }
        if let token = base.as(DeclReferenceExprSyntax.self)?.baseName,
           token.tokenKind == .keyword(.self) || token.tokenKind == .keyword(.Self)
        {
            return .enclosingSelf
        }
        let written = base.as(FunctionCallExprSyntax.self).map { writtenType($0.calledExpression) } ?? writtenType(base)
        return written.map { CallReceiver.type($0.name, mayBeUnseen: $0.isQualified, isQualified: $0.isQualified) }
    }

    /// The receiver of a name written as a use rather than called: the types the site is written in for a bare name, what the member is written on for one behind a dot, or `nil` for a key-path component and a leading-dot member, whose type the scan cannot tell.
    static func ofUse(_ name: DeclReferenceExprSyntax) -> CallReceiver? {
        if let member = name.parent?.as(MemberAccessExprSyntax.self), member.declName.id == name.id {
            return of(ExprSyntax(member))
        }
        return name.parent?.is(KeyPathPropertyComponentSyntax.self) == true ? nil : .enclosingSelf
    }

    /// The simple name of the type an expression spells — `Depot` for `Depot`, `App.Depot`, `Depot<Int>` or `Depot.init` — and whether it is written behind a dot, or `nil` for anything not capitalised like a type.
    private static func writtenType(_ expression: ExprSyntax) -> (name: String, isQualified: Bool)? {
        if let generic = expression.as(GenericSpecializationExprSyntax.self) {
            return writtenType(generic.expression)
        }
        let member = expression.as(MemberAccessExprSyntax.self)
        if let member, member.declName.baseName.tokenKind == .keyword(.`init`) {
            return member.base.flatMap(writtenType)
        }
        let token = expression.as(DeclReferenceExprSyntax.self)?.baseName ?? member?.declName.baseName
        guard let token, case .identifier = token.tokenKind else { return nil }
        let name = token.identifier?.name ?? token.text
        return name.first?.isUppercase == true ? (name, member != nil) : nil
    }

    /// The scope an expression writes a type under — `Outer.Middle` for `Outer<Int>.Middle` — or `nil` for `self`, `Self` and anything but a plain dotted path.
    static func writtenPath(_ expression: ExprSyntax?) -> String? {
        if let generic = expression?.as(GenericSpecializationExprSyntax.self) {
            return writtenPath(generic.expression)
        }
        if let member = expression?.as(MemberAccessExprSyntax.self) {
            return writtenPath(member.base).map { $0 + "." + member.declName.baseName.text }
        }
        guard let token = expression?.as(DeclReferenceExprSyntax.self)?.baseName, case .identifier = token.tokenKind else { return nil }
        return token.identifier?.name ?? token.text
    }

    /// The receiver as written at a site inside `generics`, and inside an extension where the flag says so: `nil` for a generic parameter, which may stand for any type.
    func scoped(generics: [Set<String>], inExtension: Bool) -> CallReceiver? {
        guard case let .type(name, mayBeUnseen, isQualified) = self else { return self }
        guard !generics.contains(where: { $0.contains(name) }) else { return nil }
        return .type(name, mayBeUnseen: mayBeUnseen || inExtension, isQualified: isQualified)
    }
}
