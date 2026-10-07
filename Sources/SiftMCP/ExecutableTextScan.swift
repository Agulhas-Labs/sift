//
// Copyright © Agulhas Labs
//

import Foundation

/// What ``ShellSyntax/executableText(of:)`` carries from one character to the next, so a scan can be stopped at a line and taken up again there.
///
/// The one reading of quotes, escapes and substitutions this module has: the whole-text scan steps it over every character, and ``ExecutableTextCursor`` steps it only as far as a caller has looked, resuming from a saved state after a heredoc body is skipped rather than scanning the command again from its start.
struct ExecutableTextScan {
    private var quote: Character?
    private var substitutionDepth = 0
    private var inBacktick = false
    private var previous: Character?
    private var escaped = false

    /// Whether the text scanned so far ends inside a quote, a substitution, a backtick run or after a lone backslash, so the shell would read on for the rest of it.
    var endsOpen: Bool {
        quote != nil || substitutionDepth > 0 || inBacktick || escaped
    }

    /// Appends what the shell would run of `character` to `result`: the character itself, or a space where it is quoted or escaped literal text.
    ///
    /// A `(` opening a substitution inside double quotes also puts back the `$` before it, which was blanked a character ago, so the last element of `result` may change.
    mutating func append<Output: RangeReplaceableCollection & BidirectionalCollection>(_ character: Character, to result: inout Output) where Output.Element == Character {
        // An escaped `$` is a literal dollar sign, so it opens nothing for the `(` after it.
        let literal = escaped
        defer { previous = literal ? nil : character }
        if escaped {
            // An escaped character is a literal, inside double quotes or out: `\>` is an argument, not a
            // redirect, and `\|` is not a pipe.
            escaped = false
            result.append(" ")
            return
        }
        if substitutionDepth > 0 || inBacktick {
            result.append(character)
            switch character {
            case "(" where previous == "$": substitutionDepth += 1
            case ")" where substitutionDepth > 0: substitutionDepth -= 1
            case "`": inBacktick.toggle()
            default: break
            }
            return
        }
        if character == "\\", quote != "'" {
            escaped = true
            result.append(quote == nil ? character : " ")
            return
        }
        if let open = quote {
            switch character {
            case open:
                quote = nil
                result.append(character)
            case "(" where open == "\"" && previous == "$":
                // The `$` was blanked a character ago; restore it so the span reads as written.
                result.removeLast()
                result.append(contentsOf: "$(")
                substitutionDepth += 1
            case "`" where open == "\"":
                inBacktick = true
                result.append(character)
            default:
                result.append(" ")
            }
            return
        }
        switch character {
        case "\"", "'":
            quote = character
            result.append(character)
        case "(" where previous == "$":
            substitutionDepth += 1
            result.append(character)
        case ")" where substitutionDepth > 0:
            substitutionDepth -= 1
            result.append(character)
        case "`":
            inBacktick = true
            result.append(character)
        default:
            result.append(character)
        }
    }
}
