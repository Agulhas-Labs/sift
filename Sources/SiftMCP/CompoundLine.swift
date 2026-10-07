//
// Copyright © Agulhas Labs
//

import Foundation

/// A line of two lookups or more answered as the whole of what it asked: every statement a lookup answered on its own, a literal `echo` or `printf`, or a literal `cd`, with every joint between them proven.
///
/// **Nothing on the line goes unaccounted for.** Each lookup is answered in command order and each literal's text printed verbatim where it falls, so the answer stands for the whole command (``InPlaceShape/Match/isWholeCommand``) rather than one statement of it. One statement that is anything else — an `ls`, an `echo` of a variable, a lookup this cannot answer — and the line is read as it always was, by the shell matcher's own rules (``InPlaceShape``): a line with one lookup beside nothing but literals and moves keeps the partial answer it has always had, and one beside anything else runs.
///
/// **A joint is proven or the line is not matched.** A statement and the `||` fallbacks after it are one unit, and the fallbacks are never read, since they never run. A unit has to prove its success where a fallback could print, or where an `&&` follows it with no fallback: a lookup by ``InPlaceShape/provesItsSuccess(_:answeredBy:)``, a `cd` by its directory being there, and a literal always, since printing to the terminal is what it does. A backgrounding `&` anywhere refuses.
///
/// **One directory for the lookups.** Every lookup resolves against the same directory, so a `cd` may open the line or sit where no lookup follows it, and never between two. Windows of one file share its one digest, as several reads always have; a file read whole twice, or whole beside a window of it, refuses the line.
struct CompoundLine {
    /// The match `statements` are as one compound line, or `nil` where any statement is something else, a joint is not proven, or fewer than two lookups ask anything but a document's outline.
    static func match(
        _ command: String,
        statements: [(statement: String, range: Range<String.Index>)],
        joints: [String],
        in directory: String?,
        ridingAlong: (String) -> Bool
    ) -> InPlaceShape.Match? {
        guard statements.count > 1, let last = statements.last,
              command[last.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              joints.allSatisfy({ InPlaceShape.sequences($0) || $0 == "||" })
        else {
            return nil
        }
        var line = CompoundLineParts()
        var directory = directory
        var index = 0
        while index < statements.count {
            var end = index
            while end < joints.count, joints[end] == "||" {
                end += 1
            }
            let fallbacks = statements[(index + 1) ..< (end + 1)]
            let needsProof = fallbacks.isEmpty
                ? end < joints.count && joints[end] == "&&"
                : !fallbacks.allSatisfy { InPlaceShape.isSilentFallback($0.statement) }
            let statement = statements[index].statement
            index = end + 1
            // A fallback runs only where its unit fails, and every unit here is proven or has none that print.
            let neverRun = fallbacks.map(\.statement)
            if InPlaceShape.movesDirectory(statement) {
                guard let moved = InPlaceShape.changeOfDirectory(statement),
                      let resolved = InPlaceShape.resolve(moved, against: directory),
                      isDirectory(resolved)
                else {
                    return nil
                }
                directory = resolved
                line.unattached += neverRun
            } else if let text = printedText(of: statement) {
                line.literals[line.calls.count, default: ""] += text
                line.unattached += neverRun
            } else {
                guard !ridingAlong(statement), !isNegated(statement),
                      let found = InPlaceShape.call(forStatement: statement),
                      !needsProof || InPlaceShape.provesItsSuccess(statement, answeredBy: found),
                      line.add(found, from: InPlaceShape.operandDirectory(directory, reading: statement), answering: [statement] + neverRun)
                else {
                    return nil
                }
                line.proves = line.proves || needsProof
            }
        }
        return line.match
    }

    /// Whether a statement opens on `!`, which negates its status: what it would print is unchanged, but its success is no longer the lookup's own.
    private static func isNegated(_ statement: String) -> Bool {
        statement.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace } == "!"
    }

    /// Whether `path` names a directory that is there, which a `cd` to it moves into.
    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The text a literal `echo` or `printf` statement prints, exactly as both bash and zsh print it, or `nil` where the statement is anything else.
    ///
    /// Every word is literal: quoted, or unquoted from a set of characters no shell expands or reads as an operator, and never opening on `=` (zsh's `=command` expansion). A backslash is refused anywhere, since zsh's `echo` reads escapes where bash's does not. An `echo` whose first argument opens on `-` is taken only where that argument is all dashes, two or more: `echo -n` is an option, and zsh reads a lone `-` as the end of them. A `printf` is taken only as `printf '%s\n' words…`, a line per word, or as a format with no `%` and no backslash and nothing after it, printed as it stands.
    static func printedText(of statement: String) -> String? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = arguments(of: trimmed, after: "echo") {
            guard isLiteral(rest) else { return nil }
            let words = ShellSyntax.argumentTokens(of: String(rest)).map(\.unquoted)
            if let first = words.first, first.hasPrefix("-") {
                guard first.count >= 2, first.allSatisfy({ $0 == "-" }) else { return nil }
            }
            return words.joined(separator: " ") + "\n"
        }
        guard let rest = arguments(of: trimmed, after: "printf") else { return nil }
        for format in [#"'%s\n'"#, #""%s\n""#] where rest.hasPrefix(format) {
            let words = rest.dropFirst(format.count)
            guard words.isEmpty || words.first?.isWhitespace == true, isLiteral(words) else { return nil }
            let lines = ShellSyntax.argumentTokens(of: String(words)).map { $0.unquoted + "\n" }
            return lines.isEmpty ? "\n" : lines.joined()
        }
        guard isLiteral(rest) else { return nil }
        let words = ShellSyntax.argumentTokens(of: String(rest)).map(\.unquoted)
        guard words.count == 1, let format = words.first, !format.contains("%"), !format.hasPrefix("-") else { return nil }
        return format
    }

    /// What follows `verb` where `statement` opens on it as a word of its own, or `nil` where it opens on anything else.
    private static func arguments(of statement: String, after verb: String) -> Substring? {
        guard statement.hasPrefix(verb) else { return nil }
        let rest = statement.dropFirst(verb.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return rest.drop { $0.isWhitespace }
    }

    /// Whether every word of `text` is literal: quotes closed, nothing expanded inside double quotes, no backslash, and every unquoted character from ``literalCharacters`` with no word opening on `=`.
    private static func isLiteral(_ text: Substring) -> Bool {
        var quote: Character?
        var opensWord = true
        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" || open == "\"" && "$`!".contains(character) {
                    return false
                }
                opensWord = false
                continue
            }
            if character == " " || character == "\t" {
                opensWord = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if !(character.isLetter || character.isNumber || literalCharacters.contains(character)) || opensWord && character == "=" {
                return false
            }
            opensWord = false
        }
        return quote == nil
    }

    /// The punctuation an unquoted literal word may carry: none of it expands, globs or separates in bash or zsh.
    private static let literalCharacters: Set<Character> = ["-", "_", ".", ",", ":", "/", "+", "=", "@", "%"]
}
