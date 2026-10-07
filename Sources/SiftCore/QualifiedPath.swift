//
// Copyright © Agulhas Labs
//

import Foundation

/// One dotted target — `Name`, `Module.Name`, `Type.member`, `Outer.Nested.member` — read the same way everywhere.
///
/// Both halves matter and both are easy to get subtly wrong in a second copy. Splitting has to survive a labeled form (`save(_:to:)` is one component, not three), and matching has to be done against the *flattened* enclosing chain, because an extension row's name is the extended type as written: `extension Outer.Nested` is one chain element spelling two. Compared unflattened, a member declared inside it has the chain `["Outer.Nested"]`, which no qualifier list can ever equal — so `Outer.Nested.member` would dead-end on "nearest symbols" while the list underneath printed the very declaration it had just refused, and the two-segment `Nested.member` would miss it too.
///
/// The cross-root probe compares the same way for the same reason: a pointer at another repository is a claim about a path, and a claim checked more loosely than it is worded is the one failure a pointer must not have.
///
/// `RootResolver.probeKeys` splits here too but then deliberately drops to *component* matching, which is a weaker question and stays honest by naming the component it matched rather than the path (`RootEvidence`). That is the line between them: this type says what a path means, and a caller that checks less than a path has to say less in its answer.
struct QualifiedPath {
    /// The components of a dotted target, splitting on dots outside parentheses so `save(_:to:)` survives whole.
    static func components(of target: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        for character in target {
            if character == "(" {
                depth += 1
            }
            if character == ")" {
                depth -= 1
            }
            if character == ".", depth == 0 {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        components.append(current)
        return components.filter { !$0.isEmpty }
    }

    /// A labeled form reduced to what an exact name match can find — `save(_:to:)` → `save`.
    static func baseName(of name: String) -> String {
        guard let parenIndex = name.firstIndex(of: "(") else { return name }
        return String(name[name.startIndex ..< parenIndex])
    }

    /// The names enclosing a declaration, outermost first, one element per *written* component.
    static func flattened(chain: [String]) -> [String] {
        chain.flatMap { baseName(of: $0).split(separator: ".").map(String.init) }
    }

    /// Whether a declaration whose enclosing chain is `chain`, in `module`, answers to `qualifiers`.
    ///
    /// The module is tried as the outermost element, so `Module.Type.member` resolves without the module ever being a symbol.
    static func matches(qualifiers: [String], chain: [String], module: String) -> Bool {
        guard !qualifiers.isEmpty else { return true }
        let flattenedChain = flattened(chain: chain)
        if flattenedChain.suffix(qualifiers.count) == qualifiers[...] {
            return true
        }
        return ([module] + flattenedChain).suffix(qualifiers.count) == qualifiers[...]
    }
}
