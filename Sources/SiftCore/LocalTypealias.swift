//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// A typealias declared inside a function, closure or accessor body, which the index never records, as a type use written on its right-hand side sees it.
struct LocalTypealias: Sendable, Equatable {
    let name: String
    /// The `line:column` of its name, which a use's ``SyntacticCallSite`` lists among its local declarations where the name written there may mean it.
    let declaredAt: String
    /// Whether no type is around it, so lookup there sees only top-level types and only a whole path names a nested one.
    let atTopLevel: Bool

    /// `site`, a use of the type `name` written at `node`, with the declarations its name may mean inside a function, and tagged with the function-local typealias whose right-hand side holds it as a whole path: never a member path's base alone, and never one led by a generic parameter.
    ///
    /// The flags say whether the scan is inside a function, closure or accessor body, and whether no type is around it.
    static func tagging(_ site: SyntacticCallSite, writing name: String, at node: some SyntaxProtocol, converter: SourceLocationConverter, inFunction: Bool, atTopLevel: Bool) -> SyntacticCallSite {
        guard inFunction else { return site }
        var tagged = site
        tagged.localDeclarations = declarations(of: name, around: node, converter: converter)
        guard !site.qualifiedByGenericParameter, node.parent?.as(MemberTypeSyntax.self)?.baseType.id != node.id else { return tagged }
        var ancestor = node.parent
        while let current = ancestor, !current.is(TypeInitializerClauseSyntax.self), !current.is(DeclSyntax.self) {
            ancestor = current.parent
        }
        guard let declaration = ancestor?.as(TypeInitializerClauseSyntax.self)?.parent?.as(TypeAliasDeclSyntax.self) else { return tagged }
        tagged.localTypealias = LocalTypealias(name: declaration.name.identifier?.name ?? declaration.name.text, declaredAt: position(of: declaration.name, converter: converter), atTopLevel: atTopLevel)
        return tagged
    }

    /// The types and typealiases named `name` declared in the blocks around `node`, by the `line:column` of their names, nearest first: the nearest block declaring one outside any `#if` clause ends the list, and one inside a clause is listed without ending it, since it may be compiled out.
    static func declarations(of name: String, around node: some SyntaxProtocol, converter: SourceLocationConverter) -> [String] {
        var found: [String] = []
        var ancestor = node.parent
        while let current = ancestor {
            ancestor = current.parent
            let items: [Syntax] = if let list = current.as(CodeBlockItemListSyntax.self) {
                list.map { Syntax($0.item) }
            } else if let list = current.as(MemberBlockItemListSyntax.self) {
                list.map { Syntax($0.decl) }
            } else {
                []
            }
            let named = declared(in: items, conditional: false).filter { ($0.name.identifier?.name ?? $0.name.text) == name }
            found += named.map { position(of: $0.name, converter: converter) }
            if named.contains(where: { !$0.conditional }) {
                break
            }
        }
        return found
    }
}

private extension LocalTypealias {
    /// The types and typealiases `items` declare, an `#if` clause's included, each with whether it sits in one.
    static func declared(in items: [Syntax], conditional: Bool) -> [(name: TokenSyntax, conditional: Bool)] {
        items.flatMap { item -> [(name: TokenSyntax, conditional: Bool)] in
            if let config = item.as(IfConfigDeclSyntax.self) {
                return config.clauses.flatMap { clause -> [(name: TokenSyntax, conditional: Bool)] in
                    switch clause.elements {
                    case let .statements(list): declared(in: list.map { Syntax($0.item) }, conditional: true)
                    case let .decls(list): declared(in: list.map { Syntax($0.decl) }, conditional: true)
                    default: []
                    }
                }
            }
            let name = item.as(TypeAliasDeclSyntax.self)?.name ?? item.as(StructDeclSyntax.self)?.name ?? item.as(ClassDeclSyntax.self)?.name
                ?? item.as(EnumDeclSyntax.self)?.name ?? item.as(ActorDeclSyntax.self)?.name ?? item.as(ProtocolDeclSyntax.self)?.name
            return name.map { [(name: $0, conditional: conditional)] } ?? []
        }
    }

    static func position(of token: TokenSyntax, converter: SourceLocationConverter) -> String {
        let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)
        return "\(location.line):\(location.column)"
    }
}
