//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The name a written type is declared under, so an extension of `Depot<Int>`, `[Int]` or `Int?` is matched to the type `Depot`, `Array` or `Optional` it extends.
struct DeclaredTypeName {
    /// A type's declared name: generic arguments set aside, a qualifying prefix dropped, and array, dictionary and optional sugar read as the type it stands for.
    static func of(_ type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.identifier?.name ?? identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.identifier?.name ?? member.name.text
        }
        if type.is(ArrayTypeSyntax.self) {
            return "Array"
        }
        if type.is(DictionaryTypeSyntax.self) {
            return "Dictionary"
        }
        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return "Optional"
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return of(attributed.baseType)
        }
        return type.trimmedDescription
    }

    /// A type's written dotted path with its generic arguments set aside — `Outer.Inner` for `Outer<Int>.Inner` — or `nil` for anything but a name or a member of one.
    static func path(of type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.identifier?.name ?? identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return path(of: member.baseType).map { $0 + "." + (member.name.identifier?.name ?? member.name.text) }
        }
        return nil
    }

    /// The dotted path a written type names with its generic arguments set aside — `Depot.Gizmo` for `Depot.Gizmo<Int>` — or the spelling itself where it is not a name or a member of one.
    static func path(ofSpelling spelling: String) -> String {
        var parser = Parser(spelling)
        let type = TypeSyntax.parse(from: &parser)
        return type.hasError ? spelling : path(of: type) ?? spelling
    }

    /// The declared name of the innermost type a dotted container path ends in — `Depot` for `App.Depot<Pallet.Gizmo>`, `Array` for `App.[Int]` — read past dots inside brackets.
    static func last(ofPath path: some StringProtocol) -> String {
        var depth = 0
        var start = path.startIndex
        for index in path.indices {
            switch path[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case "." where depth == 0: start = path.index(after: index)
            default: break
            }
        }
        let spelling = String(path[start...])
        var parser = Parser(spelling)
        let type = TypeSyntax.parse(from: &parser)
        return type.hasError ? spelling : of(type)
    }
}
