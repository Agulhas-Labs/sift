//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// Whether a type's name written bare means a struct, class, enum or actor declared in a function, closure or accessor body around it.
///
/// Swift looks a bare name up in the bodies around it before the types and the file around them, and a type declared in a body is in scope throughout its braces, before its declaration as after. Such a type is never one the index holds, so the line is no use of an asked type. Only the certain case says so: walking out from the site through bodies alone, the first one declaring the name declares it as a struct, class, enum or actor. A typealias of the name, which may be another name for the asked type, a declaration of the name inside an `#if` clause, a freestanding macro or an attribute the language does not define in any body walked (either may declare the name), a generic parameter of the name on a declaration walked, an extension or protocol between the site and the declaration, and the file's top level each keep the line a use. A struct or class between them, or an enum or actor where the site writes the name as a type, is walked through only where it is itself declared in a body, with no inheritance clause, generic parameter clause or attribute, and its members declare nothing of the name, outside an `#if` clause or in one, and hold no macro or attribute that may: Swift searches its members first and then the body around it, so the name means there what it means beside the type. Any other keeps the line a use, since the name may resolve where the scan cannot see: a supertype's or protocol's member, one of a protocol an enum or actor conforms to without saying so, a generic parameter, or a member a macro or an attribute introduces.
struct LocalTypeShadow {
    /// `site`, a type use writing `name` at `node`, marked as meaning a type declared in a body around it where it writes the name bare and nothing else can be meant.
    static func marking(_ site: SyntacticCallSite, writing name: String, at node: some SyntaxProtocol) -> SyntacticCallSite {
        var marked = site
        marked.meansLocalType = site.qualifier == nil && shadows(name, around: node)
        return marked
    }

    /// One file's `sites` by name, unmarked under each name the file binds as a value: a value of the name, `let Log = Other.self`, may be what an expression writing it means, so no line of it there is a local type's for certain.
    static func unmarking(_ sites: [String: [SyntacticCallSite]], boundAsValues values: Set<String>) -> [String: [SyntacticCallSite]] {
        var unmarked = sites
        for name in values where unmarked[name] != nil {
            unmarked[name] = unmarked[name]?.map { site in
                var kept = site
                kept.meansLocalType = false
                return kept
            }
        }
        return unmarked
    }

    /// Whether `name`, written bare at `node`, can only mean a type declared in a body around it.
    static func shadows(_ name: String, around node: some SyntaxProtocol) -> Bool {
        let writtenAsType = Syntax(node).is(TypeSyntax.self)
        for ancestor in sequence(first: Syntax(node), next: \.parent).dropFirst() {
            if ancestor.isProtocol(DeclGroupSyntax.self) {
                guard passesThrough(ancestor, to: name, writtenAsType: writtenAsType) else { return false }
                continue
            }
            if ancestor.is(AttributeSyntax.self) || ancestor.is(SourceFileSyntax.self) || introducesGenericParameter(name, at: ancestor) {
                return false
            }
            guard let list = ancestor.as(CodeBlockItemListSyntax.self) else { continue }
            if list.parent?.is(SourceFileSyntax.self) == true {
                return false
            }
            let conditional = list.parent?.is(IfConfigClauseSyntax.self) == true
            switch reading(of: name, in: list.map { Syntax($0.item) }, conditional: conditional) {
            case .declaresType: return true
            case .unsure: return false
            case .silent: continue
            }
        }
        return false
    }
}

extension LocalTypeShadow {
    /// What a body's statements say about `name`.
    enum Reading {
        /// They declare it only as a struct, class, enum or actor, outside any `#if` clause.
        case declaresType
        /// They may declare it as something else, or under a condition.
        case unsure
        /// They neither declare it nor hold anything that may.
        case silent
    }

    static func reading(of name: String, in items: [Syntax], conditional: Bool) -> Reading {
        var declaresType = false
        for item in items {
            if item.is(MacroExpansionDeclSyntax.self) || item.is(MacroExpansionExprSyntax.self) {
                return .unsure
            }
            if let config = item.as(IfConfigDeclSyntax.self) {
                for clause in config.clauses {
                    let nested: [Syntax] = switch clause.elements {
                    case let .statements(list): list.map { Syntax($0.item) }
                    case let .decls(list): list.map { Syntax($0.decl) }
                    default: []
                    }
                    if reading(of: name, in: nested, conditional: true) != .silent {
                        return .unsure
                    }
                }
                continue
            }
            if carriesCustomAttribute(item) {
                return .unsure
            }
            let other = item.as(TypeAliasDeclSyntax.self)?.name ?? item.as(AssociatedTypeDeclSyntax.self)?.name ?? item.as(ProtocolDeclSyntax.self)?.name
            if let other, declared(other) == name {
                return .unsure
            }
            let type = item.as(StructDeclSyntax.self)?.name ?? item.as(ClassDeclSyntax.self)?.name ?? item.as(EnumDeclSyntax.self)?.name ?? item.as(ActorDeclSyntax.self)?.name
            if let type, declared(type) == name {
                if conditional {
                    return .unsure
                }
                declaresType = true
            }
        }
        return declaresType ? .declaresType : .silent
    }

    /// Whether `item` carries an attribute outside `known`, by default the language's own, or one of `argumentless` written with an argument list: a macro attached to it may declare any name its declaration names beside it, and the index never reads the expansion.
    static func carriesCustomAttribute(_ item: Syntax, known: Set<String> = AttributeScanner.nonIntroducingAttributes(importing: []), argumentless: Set<String> = []) -> Bool {
        guard let attributes = item.asProtocol(WithAttributesSyntax.self)?.attributes, !attributes.isEmpty else { return false }
        return attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return true }
            let name = attribute.attributeName.trimmedDescription
            return !known.contains(name) || argumentless.contains(name) && (attribute.leftParen != nil || attribute.arguments != nil)
        }
    }

    /// Whether a bare `name` written inside `group`, a type around the site, is looked up past it as it would be written beside it: a struct or class, or an enum or actor where the site writes the name as a type, declared in a body, with no inheritance clause, generic parameter clause or attribute, whose members declare nothing of the name and hold nothing that may.
    ///
    /// Swift searches such a type's own members before the body around it, then the members of the protocols it conforms to, which for one written with no inheritance clause are those it conforms to without saying so. An actor is always an `Actor` and an enum with no payload `Equatable` and `Hashable`, and an extension of either protocol may declare the name as a typealias, which a name written as an expression, `Crate("d")`, `Crate.self` or `[Crate]()`, finds before the body's own type (compiled and run with Swift 6.4, in language modes 5 and 6). The same name written as a type, an annotation, a parameter, a cast or a generic argument, still means the body's own type, so an enum or actor is walked through only there. A struct or class conforms without saying so at most to `Sendable`, `BitwiseCopyable`, `Copyable` and `Escapable`, none of which may be extended, and an extension of a protocol can hold no nested type, so either is walked through wherever the name is written. An extension or a protocol never qualifies.
    private static func passesThrough(_ group: Syntax, to name: String, writtenAsType: Bool) -> Bool {
        guard group.is(StructDeclSyntax.self) || group.is(ClassDeclSyntax.self) || writtenAsType && (group.is(EnumDeclSyntax.self) || group.is(ActorDeclSyntax.self)),
              group.parent?.is(CodeBlockItemSyntax.self) == true, let declaration = group.asProtocol(DeclGroupSyntax.self),
              let generic = group.asProtocol(WithGenericParametersSyntax.self), generic.genericParameterClause == nil,
              declaration.inheritanceClause == nil, declaration.attributes.isEmpty
        else { return false }
        return reading(of: name, in: declaration.memberBlock.members.map { Syntax($0.decl) }, conditional: false) == .silent
    }

    /// Whether `declaration` declares a generic parameter `name`, which the name means throughout it.
    private static func introducesGenericParameter(_ name: String, at declaration: Syntax) -> Bool {
        declaration.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause?.parameters.contains { declared($0.name) == name } == true
    }

    private static func declared(_ token: TokenSyntax) -> String {
        token.identifier?.name ?? token.text
    }
}
