//
// Copyright © Agulhas Labs
//

import Foundation

/// A `sed -n '/START/,/END/p'` or `awk '/START/,/END/'` pattern range, read so that the lines it prints can be worked out against a file's real lines without running it.
///
/// **Only what BSD `sed` and `awk` read the way ``GrepPattern`` does.** `sed` reads a basic expression and `awk` an extended one, and neither knows `\s`, `\b`, `\<`, `\>`, `\+`, `\?` or `\|` — BSD `sed` reads `\+` as a literal plus, where a grep reads one or more — so any escape but a quoted metacharacter is refused. `awk` reads a brace no interval opened as itself, so a closing brace is read as a literal and an opening one is refused. The delimiter is `/` and nothing else.
public struct RangeRead: Equatable, Sendable {
    /// The pattern that opens the range, in the spelling ``GrepPattern`` reads.
    let start: String
    /// The pattern that closes it, or `nil` where the range runs to the end of the file (`,$p`, `,0`).
    let end: String?
    /// `.basic` for `sed`, `.extended` for `awk`.
    let dialect: GrepPattern.Dialect

    /// The range `invocation` prints and the file it prints it from — `sed -n '/S/,/E/p' F`, `awk '/S/,/E/' F` — or `nil` where it is no such range or its patterns are not read exactly.
    static func reading(_ invocation: [String]) -> (file: String, range: Self)? {
        guard let verb = invocation.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        let rest = Array(invocation.dropFirst())
        let range: Self?
        switch verb {
        case "sed":
            guard rest.count == 3, rest[0] == "-n" else { return nil }
            range = sedScript(rest[1])
        case "awk":
            guard rest.count == 2 else { return nil }
            range = awkProgram(rest[0])
        default:
            return nil
        }
        guard let range, let file = rest.last, !file.hasPrefix("-") else { return nil }
        return (file, range)
    }

    /// The lines the range prints from `source`, where they are one run proven from the file's own lines — `nil` where START matches any number of lines but one, END matches none after it, or any line needed is undecided.
    ///
    /// A range that runs to the end of the file is given without the blank lines that close it.
    func printedLines(of source: [String]) -> ClosedRange<Int>? {
        let options = GrepPattern.Options(dialect: dialect)
        guard let opening = GrepPattern(start, options: options) else { return nil }
        // A range restarts at a later START match, so START has to match once in the whole file.
        var first: Int?
        for (index, line) in source.enumerated() {
            guard let matched = opening.matches(Array(line.utf8)) else { return nil }
            if matched {
                guard first == nil else { return nil }
                first = index + 1
            }
        }
        guard let first else { return nil }
        guard let end else {
            let last = (source.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1) + 1
            return last >= first ? first ... last : nil
        }
        guard let closing = GrepPattern(end, options: options) else { return nil }
        // `awk` tries END on the line START opened on, `sed` only from the next line.
        let from = dialect == .extended ? first : first + 1
        guard from <= source.count else { return nil }
        for number in from ... source.count {
            guard let matched = closing.matches(Array(source[number - 1].utf8)) else { return nil }
            if matched {
                return first ... number
            }
        }
        return nil
    }

    /// `/START/,/END/p` or `/START/,$p`, and nothing else.
    private static func sedScript(_ script: String) -> Self? {
        guard let (start, afterStart) = literal(script[...], dialect: .basic), afterStart.first == "," else { return nil }
        let tail = afterStart.dropFirst()
        if tail == "$p" {
            return Self(start: start, end: nil, dialect: .basic)
        }
        guard let (end, afterEnd) = literal(tail, dialect: .basic), afterEnd == "p" else { return nil }
        return Self(start: start, end: end, dialect: .basic)
    }

    /// `/START/,/END/` or `/START/,0`, with blanks around the comma and an action that prints each line whole.
    private static func awkProgram(_ program: String) -> Self? {
        let trimmed = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (start, afterStart) = literal(trimmed[...], dialect: .extended) else { return nil }
        var tail = afterStart.drop { $0 == " " || $0 == "\t" }
        guard tail.first == "," else { return nil }
        tail = tail.dropFirst().drop { $0 == " " || $0 == "\t" }
        let end: String?
        if tail.first == "0" {
            end = nil
            tail = tail.dropFirst()
        } else {
            guard let (closing, afterEnd) = literal(tail, dialect: .extended) else { return nil }
            end = closing
            tail = afterEnd
        }
        let action = tail.trimmingCharacters(in: .whitespaces)
        guard action.isEmpty || action.wholeMatch(of: ShellQuery.awkPrintsEachLine) != nil else { return nil }
        return Self(start: start, end: end, dialect: .extended)
    }

    /// The pattern of the `/…/` literal `text` opens with, rewritten for ``GrepPattern``, and the text after it — or `nil` where there is none or it is not read exactly.
    private static func literal(_ text: Substring, dialect: GrepPattern.Dialect) -> (String, Substring)? {
        guard text.first == "/" else { return nil }
        let quoted: Set<Character> = dialect == .basic ? [".", "*", "[", "]", "^", "$", "\\", "/", "(", ")", "{", "}"] : [".", "*", "[", "]", "^", "$", "\\", "/", "(", ")", "+", "?", "|"]
        var pattern = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "/" {
                let rest = text[text.index(after: index)...]
                guard GrepPattern(pattern, options: GrepPattern.Options(dialect: dialect)) != nil else { return nil }
                return (pattern, rest)
            }
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex, quoted.contains(text[next]) else { return nil }
                pattern += "\\" + String(text[next])
                index = text.index(after: next)
                continue
            }
            if dialect == .extended, character == "{" {
                return nil
            }
            pattern += dialect == .extended && character == "}" ? "\\}" : String(character)
            index = text.index(after: index)
        }
        return nil
    }
}
