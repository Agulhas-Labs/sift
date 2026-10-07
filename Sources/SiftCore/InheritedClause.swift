//
// Copyright © Agulhas Labs
//

/// How an inheritance clause entry, as the index stores it, writes a protocol's name: alone or as one component of a composition (`A & B`, parenthesised or not), qualified, with generic arguments, or after a word such as an attribute.
///
/// The one reader of a stored entry's components, so the conformers list, the direct mark and the qualifier mark agree on which entries name a protocol.
struct InheritedClause {
    /// Each component of `inherited`'s entries that names `name`, as written with its qualifier and without generic arguments: `Log.Shelf.Answer` for `Sendable & Log.Shelf.Answer<Int>` asked `Answer`.
    static func components(of inherited: [String], naming name: String) -> [String] {
        inherited.flatMap { entry in
            components(of: entry).filter { $0.split(separator: ".").last.map(String.init) == name }
        }
    }

    /// Whether some entry of `inherited` names `name`, alone or in a composition.
    static func names(_ name: String, in inherited: [String]) -> Bool {
        !components(of: inherited, naming: name).isEmpty
    }

    /// The type paths an entry composes, split on each `&` outside generic arguments, each its last word with comments, parentheses and generic arguments dropped.
    ///
    /// The `>` of a `->` closes nothing.
    static func components(of entry: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        var previous: Character?
        for character in uncommented(entry) {
            defer { previous = character }
            switch character {
            case "<":
                depth += 1
            case ">" where previous != "-":
                depth = max(0, depth - 1)
            case ">":
                break
            case "&" where depth == 0:
                components.append(current)
                current = ""
            case "(", ")":
                break
            default:
                if depth == 0 {
                    current.append(character)
                }
            }
        }
        components.append(current)
        return components.compactMap { component in
            component.split(whereSeparator: \.isWhitespace).last.map(String.init)
        }
    }

    /// `text` without its `//` line comments and `/* */` block comments, each block comment standing for one space so the words either side stay apart.
    private static func uncommented(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while let character = rest.first {
            if rest.hasPrefix("//") {
                rest = rest.firstIndex(of: "\n").map { rest[$0...] } ?? ""
            } else if rest.hasPrefix("/*") {
                result.append(" ")
                rest = rest.dropFirst(2)
                rest = rest.firstRange(of: "*/").map { rest[$0.upperBound...] } ?? ""
            } else {
                result.append(character)
                rest = rest.dropFirst()
            }
        }
        return result
    }
}
