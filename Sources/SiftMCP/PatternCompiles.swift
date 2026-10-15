//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a grep's pattern has balanced groups in the dialect the command uses, which is the one way a pattern the hook reads as a name fails to compile where the command runs it.
///
/// In basic grep `\(` opens a group, so `Widget\.spin\(` — a member's call written the extended way — is unbalanced and the command exits 2 with its own one-line error. An answer to it would end by offering that very command as the re-run, so the hook withholds instead and lets the command print its error. Only the group balance is checked, not the pattern's whole grammar.
struct PatternCompiles {
    /// Whether `pattern` has as many group closes as opens in `dialect`, none closing before it opens; a fixed string always compiles.
    static func balanced(_ pattern: String, dialect: GrepPattern.Dialect) -> Bool {
        guard dialect != .fixed else { return true }
        let basic = dialect == .basic
        let characters = Array(pattern)
        var depth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if basic, next == "(" || next == ")" {
                        depth += next == "(" ? 1 : -1
                    }
                }
                index += 2
                if depth < 0 {
                    return false
                }
                continue
            case "[":
                guard let after = afterBracket(characters, opening: index, escapes: !basic) else { return false }
                index = after
                continue
            case "(" where !basic:
                depth += 1
            case ")" where !basic:
                depth -= 1
            default:
                break
            }
            if depth < 0 {
                return false
            }
            index += 1
        }
        return depth == 0
    }

    /// The index after the bracket expression opening at `opening`, or nil where it never closes (every tool rejects an unclosed class): a `]` first in it, after any `^`, is a member, and `[:class:]` holds its own `]`.
    ///
    /// Where `escapes`, a backslash inside it escapes the character after it, so `[\](]` is a class of `]` and `(`: the extended dialect here is what `ugrep` and `rg` run for the `Grep` tool and a shell `grep -E`, and both read it so, where POSIX would take the backslash as a member and close the class at that `]`. Basic grep keeps the POSIX reading.
    private static func afterBracket(_ characters: [Character], opening: Int, escapes: Bool) -> Int? {
        var index = opening + 1
        if index < characters.count, characters[index] == "^" {
            index += 1
        }
        if index < characters.count, characters[index] == "]" {
            index += 1
        }
        while index < characters.count {
            if characters[index] == "[", index + 1 < characters.count, characters[index + 1] == ":" {
                if let close = (index + 2 ..< max(index + 2, characters.count - 1)).first(where: { characters[$0] == ":" && characters[$0 + 1] == "]" }) {
                    index = close + 2
                    continue
                }
            }
            if escapes, characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "]" {
                return index + 1
            }
            index += 1
        }
        return nil
    }
}

extension InPlaceCall {
    /// Whether the grep this call stands in for compiles where the command runs it; `true` for a call that is no grep.
    var searchCompiles: Bool {
        let search: ShellGrep? = switch self {
        case let .declarations(_, found), let .members(found), let .references(_, found):
            found
        case let .symbols(_, _, _, proof, _, _, toolSearch):
            proof ?? toolSearch?.search
        case .fileDigest, .documentOutline, .memberRange:
            nil
        }
        guard let search else { return true }
        return PatternCompiles.balanced(search.pattern, dialect: search.options.dialect)
    }
}
