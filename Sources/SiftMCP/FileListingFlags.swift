//
// Copyright © Agulhas Labs
//

import Foundation

/// The flags with which a search prints only the names of the files it matches, or of those it does not, rather than any line of them: a closed list per tool, read off each one's own manual.
///
/// Closed, and kept per tool, because one letter means different things to each: `-L` is `--files-without-match` to `grep` and `--follow` to `rg`, which lists nothing. A spelling missing here leaves its search judged as it always was, which is the safe direction to be wrong in.
struct FileListingFlags {
    /// The single letters asking for the list, which may stand anywhere in a cluster (`-rlw`).
    let letters: Set<Character>
    /// The long spellings asking for it.
    let words: Set<String>
    /// The letters that take a value: one ends its cluster, since the rest of the word is that value, and one closing its cluster takes the next word.
    let valueLetters: Set<Character>

    /// The flags of the search verb `verb`, or `nil` for a verb this list does not cover.
    static func of(_ verb: String) -> FileListingFlags? {
        switch verb {
        case "grep", "egrep", "fgrep": grep
        case "rg": ripgrep
        default: nil
        }
    }

    /// `grep`, whose spellings BSD `grep` and `ugrep` share, as `egrep` and `fgrep` do.
    static let grep = FileListingFlags(
        letters: ["l", "L"],
        words: ["--files-with-matches", "--files-without-match"],
        valueLetters: ["A", "B", "C", "d", "D", "e", "f", "g", "J", "K", "m", "M", "N", "O", "t"]
    )

    /// `rg`, whose `-L` follows symbolic links and so is no list.
    static let ripgrep = FileListingFlags(
        letters: ["l"],
        words: ["--files-with-matches", "--files-without-match"],
        valueLetters: ["A", "B", "C", "d", "e", "E", "f", "g", "j", "m", "M", "r", "t", "T"]
    )

    /// Whether `options`, the words after the verb, ask for the list.
    ///
    /// A word handed over as a value is never read as a flag, so `grep -e -l` hunts the text `-l`; `--` ends the options.
    func listFiles(_ options: ArraySlice<String>) -> Bool {
        var index = options.startIndex
        while index < options.endIndex {
            let word = options[index]
            index += 1
            if word == "--" {
                return false
            }
            if word.hasPrefix("--") {
                if words.contains(word) {
                    return true
                }
                continue
            }
            guard word.hasPrefix("-"), word.count > 1 else { continue }
            for (offset, letter) in word.dropFirst().enumerated() {
                if letters.contains(letter) {
                    return true
                }
                guard letter.isLetter, !valueLetters.contains(letter) else {
                    if offset == word.count - 2, valueLetters.contains(letter) {
                        index += 1
                    }
                    break
                }
            }
        }
        return false
    }
}

extension ShellQuery {
    /// Whether this search prints only the names of the files it matches, or of those it does not (``FileListingFlags``), read from its verb on so a wrapper's own flags (`xargs -L1`) are never taken for the search's.
    var listsFiles: Bool {
        guard searches, let verb = verbIndex else { return false }
        let name = String(arguments[verb].drop(while: { $0 == "(" || $0 == "{" }))
        return FileListingFlags.of(name)?.listFiles(arguments[(verb + 1)...]) ?? false
    }
}
