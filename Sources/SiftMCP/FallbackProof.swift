//
// Copyright © Agulhas Labs
//

import Foundation

/// The closed list of pipeline stages proven to exit 0 on a file that is there to read, which is what a lookup in front of a `||` fallback that could print must be for its answer to stand.
///
/// A pipeline's status is its last stage's, and the fallback runs exactly where that status is not 0, so each stage the proof stands on is one whose failure modes are all known and ruled out by its argv alone. Every form on the list was run under zsh against a real file with the system's `cat`, `head`, `tail`, `sed` and `awk`, and each exits 0; anything the list does not name is refused, however harmless it looks, since a form nobody ran is a form nobody proved.
///
/// The list, stage by stage, where "one operand" means the stage that reads the file names it and nothing else, and a later stage names no file at all: `cat` with nothing but `-n`; `head` with at most one count (`-N`, `-n N`, `-nN`, `--lines=N`, `--lines N`) whose N is 1 through 2147483647, since `head` refuses a count of 0 and one past that bound, or — the stage reading the file — one byte count (`-c N`, `-cN`) whose N is 1 through the largest `Int`; `tail` with at most one count in the same spellings, N any number, or `-n +N`/`--lines=+N` from a line; `sed` with `-n`, optionally `-E` or `-r`, and print scripts only (`-e S`, or the first bare word where there is no `-e`), each a line window whose first address is not 0, and no long option, which the system `sed` refuses; `awk` with no option at all and one program of `NR` comparisons whose body, if it has one, is `print`, an optional trailing `;`, followed only by `$0`, `$N` of at most eight digits, `NR`, `FNR` and double-quoted separators of at most four spaces, `\t` escapes and the punctuation `:` `|` `-` `.` `,`, joined by spaces or commas, or is `printf "%s\n", $0` alone, bare or in parentheses. A stage may carry `2>/dev/null` or `2>&1` and no other redirection.
///
/// What each exclusion is: `head -0` and `head -n 2147483648` exit 1; a second count (`head -5 -n 0`, `tail -0 -n +5`) is validated and can fail; a second operand exits non-zero where it is missing, and `sed -n '1,5p' '2p' F` reads `2p` as a file; `sed --quiet` exits 1; `awk -F '[('` exits 2 on its first field, `{print $2147483647}` exits 2, and any body beyond the allowlist can write (`print > "/x"`), pipe (`print | "false"`), divide by zero or run a command. `less`, `more` and a bare `tail +N` are left off because nothing proves them here.
struct FallbackProof {
    /// The largest count the system `head` takes: one more exits 1.
    static let largestHeadCount = 2_147_483_647

    /// Whether every stage of a window pipeline is on the list, the first reading its one file and every later one reading only what it is handed.
    static func isProvenWindow(_ stages: [[String]]) -> Bool {
        guard let first = stages.first else { return false }
        return exitsZero(first, operands: 1) && stages.dropFirst().allSatisfy { exitsZero($0, operands: 0) }
    }

    /// Whether the grep `search`, run to its end under `ceiling`, prints a line and meets nothing it cannot read or decide, so every grep prints that line with no error and exits 0.
    ///
    /// A search that stopped at the ceiling is not proven: a file it never reached may be one grep cannot read, and grep then exits 2 whatever it printed.
    static func printsALine(_ search: ShellGrep, in directory: String?, under ceiling: ShellGrep.Ceiling) -> Bool {
        guard case let .printed(lines) = search.run(in: directory, ceiling: ceiling) else { return false }
        return !lines.isEmpty
    }

    /// Whether the stage `words` spells is on the list and names exactly `operands` files.
    static func exitsZero(_ words: [String], operands: Int) -> Bool {
        guard let verb = words.first, !LineWindow.placesAnOptionAfterAnOperand(words) else { return false }
        let arguments = words.dropFirst().filter { $0 != "2>/dev/null" && $0 != "2>&1" }
        guard !arguments.contains(where: isRedirection) else { return false }
        switch verb {
        case "cat":
            return arguments.allSatisfy { $0 == "-n" || !$0.hasPrefix("-") } && arguments.count(where: { !$0.hasPrefix("-") }) == operands
        case "head" where LineWindow.byteCount(arguments) != nil:
            // The count is the one option, so every other word is an operand; only the stage reading the file is
            // read to its bytes (``LineWindow``), so a later one is not on the list.
            return operands == 1 && arguments.count == operands + (arguments.contains("-c") ? 2 : 1)
        case "head", "tail":
            guard let (count, files) = countAndOperands(Array(arguments)), files.count == operands else { return false }
            guard let count else { return true }
            return verb == "head" ? isHeadCount(count) : isTailCount(count)
        case "sed":
            return sedExitsZero(Array(arguments), operands: operands)
        case "awk":
            guard let program = arguments.first, !program.hasPrefix("-"), arguments.count == operands + 1 else { return false }
            return program.wholeMatch(of: ShellQuery.awkWindow) != nil && isPrintOnlyBody(of: program)
        default:
            return false
        }
    }

    /// Whether an `awk` program carries no body, or a body of `print` and the allowlisted terms alone, so it prints the lines it picked and can do nothing else.
    ///
    /// A single trailing `;` after `print` or its terms is dropped first, since it ends the statement without adding one of its own.
    static func isPrintOnlyBody(of program: String) -> Bool {
        let program = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = program.firstIndex(of: "{") else { return true }
        guard program.hasSuffix("}") else { return false }
        if program[open...].wholeMatch(of: ShellQuery.awkPrintfsEachLine) != nil {
            return true
        }
        let body = program[program.index(after: open) ..< program.index(before: program.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("print") else { return false }
        var rest = body.dropFirst("print".count)
        if rest.hasSuffix(";") {
            rest = rest.dropLast()
        }
        guard !rest.isEmpty else { return true }
        guard rest.first?.isWhitespace == true else { return false }
        return printsOnlyTerms(rest.drop { $0.isWhitespace })
    }

    /// Whether `text` is one or more allowlisted terms, each after the first following spaces, a comma, or nothing.
    private static func printsOnlyTerms(_ text: Substring) -> Bool {
        var rest = text
        while true {
            guard let afterTerm = droppingTerm(from: rest) else { return false }
            rest = afterTerm.drop { $0 == " " || $0 == "\t" }
            if rest.isEmpty {
                return true
            }
            if rest.first == "," {
                rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            }
        }
    }

    /// `text` after the one allowlisted term it opens on, or `nil` where it opens on none.
    private static func droppingTerm(from text: Substring) -> Substring? {
        if text.first == "$" {
            let digits = text.dropFirst().prefix { $0.isASCII && $0.isNumber }
            guard (1 ... 8).contains(digits.count) else { return nil }
            return endsWord(text.dropFirst(1 + digits.count))
        }
        if text.first == "\"" {
            guard let match = text.firstMatch(of: ShellQuery.awkPrintSeparator), match.range.lowerBound == text.startIndex else { return nil }
            return text[match.range.upperBound...]
        }
        for name in ["FNR", "NR"] where text.hasPrefix(name) {
            return endsWord(text.dropFirst(name.count))
        }
        return nil
    }

    /// `rest` where it does not carry on the word before it — a letter, digit or `_` would make `NRX` or `$1x` a different term.
    private static func endsWord(_ rest: Substring) -> Substring? {
        guard let next = rest.first else { return rest }
        return next.isLetter || next.isNumber || next == "_" ? nil : rest
    }

    /// The one count a `head` or `tail` stage carries, if any, and its operands, or `nil` where it carries two counts or any other option.
    private static func countAndOperands(_ arguments: [String]) -> (count: String?, operands: [String])? {
        var count: String?
        var operands: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            var value: String?
            if word == "-n" || word == "--lines" {
                index += 1
                guard index < arguments.endIndex else { return nil }
                value = arguments[index]
            } else if word.hasPrefix("--lines=") {
                value = String(word.dropFirst("--lines=".count))
            } else if word.hasPrefix("-n") {
                value = String(word.dropFirst(2))
            } else if word.hasPrefix("-") {
                value = String(word.dropFirst())
                guard let first = value?.first, first.isASCII, first.isNumber else { return nil }
            } else if word.hasPrefix("+") {
                return nil
            } else {
                operands.append(word)
            }
            if let value {
                guard count == nil else { return nil }
                count = value
            }
            index += 1
        }
        return (count, operands)
    }

    /// Whether `count` is a number of lines the system `head` takes: 1 through ``largestHeadCount``.
    private static func isHeadCount(_ count: String) -> Bool {
        guard isDigits(count), let lines = Int(count) else { return false }
        return (1 ... largestHeadCount).contains(lines)
    }

    /// Whether `count` is a number of lines the system `tail` takes, or `+N` for a line to start from.
    private static func isTailCount(_ count: String) -> Bool {
        let number = count.hasPrefix("+") ? String(count.dropFirst()) : count
        return isDigits(number) && Int(number) != nil
    }

    /// Whether a `sed` stage is `-n` and print windows alone, naming exactly `operands` files.
    private static func sedExitsZero(_ arguments: [String], operands: Int) -> Bool {
        var quiet = false
        var scripts: [String] = []
        var bare: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let word = arguments[index]
            if word == "-n" {
                quiet = true
            } else if word == "-E" || word == "-r" {
                // Extended expressions: taken by the system `sed` and by GNU's, and no window reads a pattern.
            } else if word == "-e" {
                index += 1
                guard index < arguments.endIndex else { return false }
                scripts.append(arguments[index])
            } else if word.hasPrefix("-") {
                return false
            } else {
                bare.append(word)
            }
            index += 1
        }
        if scripts.isEmpty, !bare.isEmpty {
            scripts.append(bare.removeFirst())
        }
        guard quiet, !scripts.isEmpty, bare.count == operands else { return false }
        return scripts.allSatisfy { script in
            script.wholeMatch(of: ShellQuery.sedWindow) != nil
                && script.split(separator: ";").allSatisfy { Int($0.prefix { $0.isASCII && $0.isNumber }).map { $0 >= 1 } ?? false }
        }
    }

    /// Whether `text` is one or more ASCII digits.
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Whether `word` redirects a stream, which sends the output, or takes the input, somewhere this cannot follow.
    private static func isRedirection(_ word: String) -> Bool {
        word.hasPrefix("<") || word.hasPrefix(">") || word.hasPrefix("&>") || word.contains(/^[0-9]+>/)
    }
}
