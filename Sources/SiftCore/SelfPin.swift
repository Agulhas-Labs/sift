//
// Copyright © Agulhas Labs
//

import SwiftSyntax

/// The type an extension's where clause pins `Self` to — `extension Maker where Self == Lid` — whose initializer a `Self(x)` in it calls.
///
/// Only a same-type requirement pins it, and only to a type written as a plain name: `Self == Box<Int>` pins `Box`; a conformance `Self: Maker`, a member type `M.T` or an optional pins nothing, and the call stays one on a type the scan cannot tell.
struct SelfPin {
    /// The simple name of the type `clause` makes `Self`, or `nil` where it makes it none.
    static func type(in clause: GenericWhereClauseSyntax?) -> String? {
        for requirement in clause?.requirements ?? [] {
            guard case let .sameTypeRequirement(sameType) = requirement.requirement,
                  case let .type(left) = sameType.leftType,
                  case let .type(right) = sameType.rightType
            else { continue }
            if isSelf(left), let name = plainName(right) {
                return name
            }
            if isSelf(right), let name = plainName(left) {
                return name
            }
        }
        return nil
    }

    private static func isSelf(_ type: TypeSyntax) -> Bool {
        type.as(IdentifierTypeSyntax.self)?.name.tokenKind == .keyword(.Self)
    }

    /// The name a type written as a plain name spells, its generic arguments set aside, or `nil` for any other type.
    private static func plainName(_ type: TypeSyntax) -> String? {
        guard let name = type.as(IdentifierTypeSyntax.self)?.name, case .identifier = name.tokenKind else { return nil }
        return name.identifier?.name ?? name.text
    }
}
