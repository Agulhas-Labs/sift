//
// Copyright © Agulhas Labs
//

/// Reads attribute names out of signature slices — powering the macro honesty marker and `--signatures-only`.
struct AttributeScanner {
    /// Attributes the compiler defines; anything else on a type is treated as a possible macro (Docs/Design.md §8 — never silently under-report).
    ///
    /// Each but `MainActor` is a spelling the compiler's own attribute tables carry, which parses as that attribute wherever it is written, so no macro is applied under it. `MainActor` is the standard library's global actor, written as a custom attribute: a macro of that name in a module the file sees is applied instead, so the digest marker's list holds it and ``nonIntroducingAttributes(importing:)`` does not. A macro the SDK ships, `Observable`, `Model`, `Test` or `Suite`, stays custom, since it may add members or peers.
    static var builtinAttributes: Set<String> {
        [
            "available", "objc", "objcMembers", "nonobjc", "MainActor", "discardableResult", "frozen",
            "inlinable", "inline", "usableFromInline", "dynamicCallable", "dynamicMemberLookup", "Sendable",
            "preconcurrency", "resultBuilder", "propertyWrapper", "escaping", "autoclosure", "testable",
            "NSCopying", "NSManaged", "IBOutlet", "IBAction", "IBDesignable", "IBInspectable", "GKInspectable",
            "attached", "freestanding", "warn_unqualified_access", "unknown", "retroactive", "unchecked",
            "convention", "Sendable", "concurrent", "isolated", "globalActor", "main", "NSApplicationMain",
            "UIApplicationMain", "implementation", "nonexhaustive", "requires_stored_property_inits", "safe", "unsafe",
            "_exported", "_implementationOnly", "_spi", "_spiOnly", "backDeployed", "_documentation",
            "_disfavoredOverload", "_alwaysEmitIntoClient", "IBSegueAction", "_silgen_name", "_cdecl",
        ]
    }

    /// SDK macros that declare no name a user writes at file scope, each by the modules whose import brings it into a file: `Test` and `Suite` are peer macros without `names:`, so they add only unique names, and `Observable` and `Model` add members, member attributes and conformances, never a peer.
    ///
    /// The modules are where each is declared and those that re-export it: `Observation` is re-exported by `SwiftData` and `Foundation`, and `SwiftUI` makes it visible too. Without one of them imported the name may be anyone's macro. The digest's marker ignores this table, because what it warns of, members the parser cannot see, these macros do add.
    ///
    /// The table reads spellings, not resolutions: a macro of the same name in a third-party package the file also imports, which the index never reads, may be the one applied. That gap is accepted, narrowed by `argumentlessMacros` and `macrosTakingArguments`.
    static var fileScopeMacrosByModule: [String: Set<String>] {
        [
            "Test": ["Testing"],
            "Suite": ["Testing"],
            "Observable": ["Observation", "SwiftUI", "SwiftData", "Foundation"],
            "Model": ["SwiftData"],
        ]
    }

    /// The SDK macros whose declarations take no arguments, so one written with an argument list, `@Observable()` or `@Observable(tag: 1)`, is another module's overload and stays custom.
    static var argumentlessMacros: Set<String> {
        ["Observable", "Model"]
    }

    /// The SDK macros whose declarations take arguments, so an overload of the same spelling cannot be told apart by its argument list: each stays custom while any file of the tree declares a macro of its name.
    static var macrosTakingArguments: Set<String> {
        ["Test", "Suite", "Preview"]
    }

    /// The attributes that declare no name at file scope in a file importing `modules`: the language's own, bar `MainActor`, which another module's macro of that name may replace, and the SDK macros those imports bring in.
    static func nonIntroducingAttributes(importing modules: Set<String>) -> Set<String> {
        builtinAttributes.subtracting(["MainActor"]).union(macros(in: fileScopeMacrosByModule, importing: modules))
    }

    /// SDK freestanding macros that declare no name, each by the modules whose import brings it into a file: `#Preview` is `@freestanding(declaration)` without `names:` in SwiftUI, UIKit, AppKit and WidgetKit, so its expansion introduces nothing a user writes.
    static var freestandingMacrosByModule: [String: Set<String>] {
        ["Preview": ["SwiftUI", "UIKit", "AppKit", "WidgetKit"]]
    }

    /// The freestanding macros that declare no name at file scope in a file importing `modules`.
    static func nonIntroducingFreestandingMacros(importing modules: Set<String>) -> Set<String> {
        macros(in: freestandingMacrosByModule, importing: modules)
    }

    /// The names in `table` that some module of `modules` brings in.
    private static func macros(in table: [String: Set<String>], importing modules: Set<String>) -> Set<String> {
        Set(table.compactMap { $0.value.isDisjoint(with: modules) ? nil : $0.key })
    }

    /// Attribute names in the signature that are not compiler builtins — property wrappers and macros alike; the digest cannot tell them apart and says so.
    static func customAttributeNames(in signature: String) -> [String] {
        attributeNames(in: signature).filter { !builtinAttributes.contains($0) }
    }

    /// Every `@Name` occurrence in the signature, in order.
    static func attributeNames(in signature: String) -> [String] {
        var names: [String] = []
        var characters = Substring(signature)
        while let atIndex = characters.firstIndex(of: "@") {
            characters = characters[characters.index(after: atIndex)...]
            let name = characters.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty {
                names.append(String(name))
            }
        }
        return names
    }

    /// The text between the parentheses of `@Name(…)`, or `nil` when the signature carries no such attribute or writes it without arguments.
    ///
    /// The parenthesis is the name boundary too: `@Testing` is not `@Test`, because what follows the shorter name there is a letter rather than an open parenthesis.
    static func attributeArguments(in signature: String, named name: String) -> String? {
        arguments(in: signature, after: "@" + name)
    }

    /// The text between the parentheses of a trait written in dot form — `.disabled("not ready")` inside an attribute's own argument slice.
    static func traitArguments(in text: String, named name: String) -> String? {
        arguments(in: text, after: "." + name)
    }

    /// The content of the first string literal in the slice, as written between its quotes, or `nil` when it carries none.
    static func firstStringLiteral(in text: String) -> String? {
        var index = text.startIndex
        while index < text.endIndex, text[index] != "\"" {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        var content = ""
        index = text.index(after: index)
        while index < text.endIndex, text[index] != "\"" {
            if text[index] == "\\", text.index(after: index) < text.endIndex {
                index = text.index(after: index)
            }
            content.append(text[index])
            index = text.index(after: index)
        }
        return index < text.endIndex ? content : nil
    }

    /// The argument slice of the first `marker(` in the text, with nesting and string literals accounted for.
    private static func arguments(in text: String, after marker: String) -> String? {
        var searchStart = text.startIndex
        while let found = text.range(of: marker, range: searchStart ..< text.endIndex) {
            searchStart = found.upperBound
            guard found.upperBound < text.endIndex, text[found.upperBound] == "(" else { continue }
            if let close = closingParenthesis(in: text, from: found.upperBound) {
                return String(text[text.index(after: found.upperBound) ..< close])
            }
        }
        return nil
    }

    /// The index of the parenthesis closing the one at `open`, or `nil` when the text ends first.
    private static func closingParenthesis(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inStringLiteral = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inStringLiteral {
                if character == "\\" {
                    index = text.index(after: index)
                } else if character == "\"" {
                    inStringLiteral = false
                }
            } else if character == "\"" {
                inStringLiteral = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The signature with leading attributes removed (`@Wrapped(arg) @Other func` → `func`), for `--signatures-only`.
    static func strippingLeadingAttributes(_ signature: String) -> String {
        var text = Substring(signature)
        while text.hasPrefix("@") {
            text = text.dropFirst()
            text = text.drop { $0.isLetter || $0.isNumber || $0 == "_" }
            if text.hasPrefix("(") {
                var depth = 0
                var index = text.startIndex
                while index < text.endIndex {
                    let character = text[index]
                    if character == "(" {
                        depth += 1
                    }
                    if character == ")" {
                        depth -= 1
                        if depth == 0 {
                            index = text.index(after: index)
                            break
                        }
                    }
                    index = text.index(after: index)
                }
                text = text[index...]
            }
            text = text.drop { $0 == " " }
        }
        return text.isEmpty ? signature : String(text)
    }
}
