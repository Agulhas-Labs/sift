//
// Copyright © Agulhas Labs
//

import Foundation

/// How a segment's redirections are read, character by character — which descriptor an operator names, which one a `>&` duplicates, and whether the destination is a file kept to be read.
///
/// Its own type because it is its own subject: ``ShellQuery`` asks it while walking a segment's redirections left to right the way the shell applies them, and nothing else in the pipeline reading needs any of it. Split out when `ShellQuery.swift` outgrew a single subject; the walk itself stays there, since what it concludes — whether the caller kept the output — is a fact about the segment rather than about a redirection.
struct ShellRedirect {
    /// The descriptor written in front of the `>` at `index`, or `nil` when none is — the operator then means stdout.
    ///
    /// Digits name a descriptor only as a word of their own: `a2>x` writes `a2` to x through stdout.
    static func descriptor(before index: Int, in text: [Character]) -> String? {
        var start = index
        while start > 0, text[start - 1].isNumber {
            start -= 1
        }
        let opensAWord = start == 0 || text[start - 1].isWhitespace || text[start - 1] == "&"
        return opensAWord && start < index ? String(text[start ..< index]) : nil
    }

    /// The descriptor a `>&` duplicates, read at `start` just past the `&` — its digits, or an empty name for `-`, which closes the stream.
    ///
    /// `nil` when a word follows instead: `>&log` names a file. Blanks before the word are skipped, as the shell skips them — `>& 2` duplicates exactly as `>&2` does, and `>& -` closes the stream.
    static func duplicatedDescriptor(at start: Int, in text: [Character]) -> String? {
        let word = text[start...].drop(while: { $0 == " " || $0 == "\t" })
        let digits = String(word.prefix(while: \.isNumber))
        if !digits.isEmpty {
            return digits
        }
        return word.first == "-" ? "" : nil
    }

    /// Whether a redirection's destination is a file kept to be read — not empty, not a device under `/dev/`, and not a process substitution, whose word opens with `>(` or `<(`.
    static func isAFile(_ destination: String) -> Bool {
        guard let first = destination.first, !destination.hasPrefix("/dev/") else {
            return false
        }
        return first != "(" && !destination.hasPrefix(">(") && !destination.hasPrefix("<(")
    }

    /// The shell word starting at `start` (leading blanks skipped), quotes removed — a redirection's destination.
    static func word(in characters: [Character], from start: Int) -> String {
        var index = start
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        var word = ""
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    word.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                break
            } else {
                word.append(character)
            }
            index += 1
        }
        return word
    }
}
