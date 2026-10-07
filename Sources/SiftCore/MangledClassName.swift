//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads back the runtime name an XCTest log prints for a class nested in another type, which is mangled where a top-level class's is dotted.
///
/// `swift test` on macOS names a top-level case `LibTests.WidgetTests`, but a case declared inside another type — `WidgetTests.GizmoTests`, or a class inside an enum used as a namespace — under its mangled Objective-C runtime name on its `Test Case '-[…]'` and `Test Suite '…'` lines alike. The inventory declares that case as `WidgetTests.GizmoTests`, the spelling `swift test list` and `--filter` use, so a log read as printed reports every nested case missing over a green run.
///
/// **One family is read, and only exactly.** `_Tt`, then one kind letter per type in the chain — `C` class, `O` enum, `V` struct — innermost first, so the first is the case's own `C`; then as many length-prefixed identifiers as there are kinds plus one, the module first and then each type outermost first. The names a real run printed for a class in a class, a class in an enum and a class three levels down are the fixtures of `NestedXCTestNameTests`. Anything else — a generic or private context, a standard-library substitution, a length that overruns or leaves text over — is not this family, and is left as printed rather than guessed at.
struct MangledClassName {
    /// The dotted name a mangled nested-class name stands for — `_TtCC8LibTests11WidgetTests10GizmoTests` gives `LibTests.WidgetTests.GizmoTests` — or `nil` where `name` is not exactly that family.
    static func demangled(_ name: Substring) -> String? {
        guard name.hasPrefix("_Tt") else {
            return nil
        }
        var rest = name.dropFirst(3)
        let kinds = rest.prefix { "COV".contains($0) }
        guard kinds.first == "C" else {
            return nil
        }
        rest = rest.dropFirst(kinds.count)
        var identifiers: [Substring] = []
        while !rest.isEmpty {
            guard let (identifier, remainder) = lengthPrefixedIdentifier(in: rest) else {
                return nil
            }
            identifiers.append(identifier)
            rest = remainder
        }
        guard identifiers.count == kinds.count + 1 else {
            return nil
        }
        return identifiers.joined(separator: ".")
    }

    /// The runtime name of the class `chain` declares, outermost type first, in module `module` — `enum ChoreTasks { class LampTests }` in `LibTests` gives `_TtCO8LibTests10ChoreTasks9LampTests` — or `nil` for a class nested in nothing, or where a link in the chain has no letter in this family, is private or file-private, or is not a plain ASCII identifier.
    static func mangled(module: String, chain: [SymbolRow]) -> String? {
        var kinds = ""
        var names = [module]
        for row in chain {
            guard let kind = kindLetter(of: row.kind),
                  row.accessLevel != .privateLevel, row.accessLevel != .fileprivateLevel,
                  row.name.first?.isNumber == false,
                  row.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else {
                return nil
            }
            kinds = String(kind) + kinds
            names.append(row.name)
        }
        guard chain.count > 1, chain.last?.kind == .classKind else {
            return nil
        }
        return "_Tt" + kinds + names.map { "\($0.count)\($0)" }.joined()
    }

    /// The letter this family spells a declaration kind with — `C` class, `O` enum, `V` struct — and `nil` for every other kind, an extension included, since it does not say what it extends.
    private static func kindLetter(of kind: SymbolKind) -> Character? {
        switch kind {
        case .classKind: "C"
        case .enumKind: "O"
        case .structKind: "V"
        default: nil
        }
    }

    /// The identifier a decimal length opens at the start of `text` and the text after it, or `nil` where the length is missing, zero-led or overruns, or the identifier is not a plain ASCII one.
    private static func lengthPrefixedIdentifier(in text: Substring) -> (Substring, Substring)? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard digits.first.map({ $0 != "0" }) == true, let length = Int(digits) else {
            return nil
        }
        let afterLength = text.dropFirst(digits.count)
        guard afterLength.count >= length else {
            return nil
        }
        let identifier = afterLength.prefix(length)
        guard identifier.first?.isNumber == false,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else {
            return nil
        }
        return (identifier, afterLength.dropFirst(length))
    }
}
