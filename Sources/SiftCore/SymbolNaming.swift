//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// The one generator for a function-like declaration's labeled name (`save(_:to:)`).
///
/// Shared rather than duplicated because the index writes it and the structural matcher reads it back: a search hit and a `where` query must spell the same declaration the same way, or a match found by shape cannot be looked up by name. A second copy would be a latent divergence even while the two agree.
struct SymbolNaming {
    static func labeledName(base: String, parameters: FunctionParameterListSyntax) -> String {
        let labels = parameters.map { parameter in
            name(of: parameter.firstName) + ":"
        }
        return base + "(" + labels.joined() + ")"
    }

    /// A declared name or argument label as the index store and `where` spell it: without the backticks that escape an ordinary word (`` `settle` ``, `` `default` ``), and with them around a raw identifier (`` `a b` ``) that cannot be written without them.
    ///
    /// A token's own `text` keeps whatever backticks the source wrote, so a declaration named through it is stored as `` `settle`() `` and a query for `settle` — or a call written `settle()` — never reaches it. A raw identifier keeps its backticks because they are part of how Swift Testing and the compiler name it.
    static func name(of token: TokenSyntax) -> String {
        guard let bare = token.identifier?.name, bare != token.text else { return token.text }
        return bare.isValidSwiftIdentifier(for: .memberAccess) ? bare : token.text
    }

    /// Whether a name, bare or labeled, is an operator's (`+`, `<~>`, `√(_:)`): one that starts with no identifier character, so it is used as `a + b`, `-a` or `b^^` rather than called by name.
    static func isOperator(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return !(first.properties.isXIDStart || first == "_" || first == "`" || first == "$" || first == "(")
    }

    /// `spelling` with every backticked ordinary word unwrapped by the rule ``name(of:)`` names a declaration by.
    ///
    /// A query written with a backticked member, or a type spelled `` `Tick` ``, then reaches the name the store holds.
    static func unbackticked(_ spelling: String) -> String {
        guard spelling.contains("`") else { return spelling }
        var result = ""
        var rest = Substring(spelling)
        while let open = rest.firstIndex(of: "`") {
            result += rest[..<open]
            let inner = rest.index(after: open)
            guard let close = rest[inner...].firstIndex(of: "`") else {
                return result + rest[open...]
            }
            let word = String(rest[inner ..< close])
            result += word.isValidSwiftIdentifier(for: .memberAccess) ? word : "`" + word + "`"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// A subscript's labeled name, by Swift's rule for subscripts rather than functions': a parameter has an argument label only when one is written before its name.
    ///
    /// `subscript(slot: Int)` is called `x[3]`, so its one word is a parameter name and its label is `_` — the index store names it `subscript(_:)`, and naming it `subscript(slot:)` as if it were a function is a name no store row carries, so the declaration never resolves. `subscript(slot slot: Int)` is called `x[slot: 3]` and keeps `slot:`; `subscript(_ slot: Int)` is `_` either way.
    static func subscriptName(parameters: FunctionParameterListSyntax) -> String {
        let labels = parameters.map { parameter in
            (parameter.secondName == nil ? "_" : name(of: parameter.firstName)) + ":"
        }
        return "subscript(" + labels.joined() + ")"
    }

    /// An enum case's name as the index store gives it: its bare word when it carries no associated values, and labeled like a function when it does.
    ///
    /// `case value(Int)` is `value(_:)` and `case pair(left: Int, right: Int)` is `pair(left:right:)` — an associated value's label is the name written first, and one with no name has none. Named by its bare word, a case with associated values is a name no store row carries, so the declaration never resolves and `where` refuses it with advice no build can satisfy.
    static func enumCaseName(of element: EnumCaseElementSyntax) -> String {
        guard let parameters = element.parameterClause?.parameters else { return name(of: element.name) }
        let labels = parameters.map { parameter in
            (parameter.firstName.map(name(of:)) ?? "_") + ":"
        }
        return name(of: element.name) + "(" + labels.joined() + ")"
    }

    /// One enum case's signature, `case` and the element as written, whitespace-collapsed like every other signature: `case a, b` is `case a` and `case b`, the comma between them belonging to neither.
    static func enumCaseSignature(of element: EnumCaseElementSyntax) -> String {
        let written = "case " + element.with(\.trailingComma, nil).trimmedDescription
        return SourceSlicer.collapsingWhitespace(in: written)
    }
}
