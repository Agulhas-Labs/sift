//
// Copyright © Agulhas Labs
//

import Foundation

/// One word of a command as the shell hands it to the program it runs, read from the word as written.
///
/// ``ShellSyntax`` keeps a backslash and the character after it together in both spellings of a word, which is right for a pattern a search reads its own escapes in and wrong for a path: `Sources/My\ Dir/*.swift` names a directory with a space in it, and the shell passes it on without the backslash.
struct ShellOperand: Equatable {
    /// The word with its quotes removed and its backslash escapes resolved: what the program receives, before the shell expands any wildcard left live in it.
    let value: String
    /// Whether a character the glob matcher reads specially — a wildcard, a bracket or a backslash — was quoted or escaped, so it reaches the program as itself and not as a pattern.
    let quotesAGlobCharacter: Bool
    /// Whether the word opens on a `~` that was quoted or escaped, which the shell hands over as a literal directory name and never as the home directory.
    let quotesLeadingTilde: Bool

    /// The characters the glob matcher reads specially.
    private static let globCharacters: Set<Character> = ["*", "?", "[", "\\"]

    /// The characters a backslash escapes inside double quotes; before any other, the backslash is kept.
    private static let escapedInDoubleQuotes: Set<Character> = ["$", "`", "\"", "\\", "\n"]

    /// The shell's reading of `raw`, or `nil` where it holds an expansion — a `$` or a backtick outside single quotes — whose value the text does not carry, or a quote left open.
    init?(raw: String) {
        let characters = Array(raw)
        var value = ""
        var quotesAGlobCharacter = false
        var quotesLeadingTilde = false
        var quote: Character?
        var index = 0
        func literal(_ character: Character) {
            quotesLeadingTilde = quotesLeadingTilde || (value.isEmpty && character == "~")
            value.append(character)
            quotesAGlobCharacter = quotesAGlobCharacter || Self.globCharacters.contains(character)
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            switch (quote, character) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case ("'", _):
                literal(character)
            case (_, "$"), (_, "`"):
                return nil
            case ("\"", "\\"):
                guard let next, Self.escapedInDoubleQuotes.contains(next) else {
                    literal(character)
                    continue
                }
                literal(next)
                index += 1
            case ("\"", _):
                literal(character)
            case (nil, "'"), (nil, "\""):
                quote = character
            case (nil, "\\"):
                guard let next else { return nil }
                literal(next)
                index += 1
            default:
                value.append(character)
            }
        }
        guard quote == nil else { return nil }
        self.value = value
        self.quotesAGlobCharacter = quotesAGlobCharacter
        self.quotesLeadingTilde = quotesLeadingTilde
    }
}
