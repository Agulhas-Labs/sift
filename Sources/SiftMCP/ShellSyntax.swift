//
// Copyright © Agulhas Labs
//

import Foundation

/// The little bit of shell grammar this tool needs: where one command ends and the next begins, and where one argument does.
///
/// Not a shell parser and not trying to be — it does not expand, strip escapes from the arguments it splits (it only declines to split at an escaped character), or read redirections beyond keeping their operators whole. It exists because two callers need the same answer and must never disagree about it: `ShellInspection` decides whether a command went around the index (a number the status line and the audit publish), and `ShellAdvice` decides what to suggest instead. A command classified as a miss by one and not understood by the other is a nudge that never arrives.
///
/// Quote-awareness is the whole point. `grep -n "a\|b" File.swift` splits on the `|` *inside the pattern* if you split naively, leaving `File.swift` in a segment with no read verb — so an alternation grep, which is a Swift lookup by any reading, would go silently uncounted.
public struct ShellSyntax {
    /// The command split on pipeline and sequencing operators, so each piece can be judged on what it acts on.
    ///
    /// Quotes are **kept**. A segment is matched against for command words, and `echo "grep Foo.swift"` must not read as a grep of a Swift file — the surviving quote is what keeps the verb from looking like one.
    public static func segments(of command: String) -> [String] {
        split(runnableText(command), on: { "|;&\n".contains($0) }, stripQuotes: false)
    }

    /// The command split on sequencing operators only, so each pipeline arrives whole.
    ///
    /// The distinction `segments` deliberately throws away, and the one caller that needs it is the advisor for `sift run`: `swift test | tail -40` is a caller managing its own output and must not be interrupted, while `cd Kit && swift test` is the same bare command with a directory change in front of it. Both are two segments; only the first is a pipeline.
    public static func statements(of command: String) -> [String] {
        splitStatements(runnableText(command))
    }

    /// What the shell would run of `command`: its comments and its heredoc bodies taken out.
    ///
    /// Comments go first, so a `<<` written in one opens no heredoc and swallows no lines after it; a body line that happens to start with `#` goes with the rest of its body either way.
    static func runnableText(_ command: String) -> String {
        withoutHeredocBodies(withoutComments(command))
    }

    /// Whether `command` is a line the shell would not run as written, and Claude Code does not split into statements, judged on its text with comments and heredoc bodies set aside and its ends trimmed: one that opens on `&&`, `||`, `|` or `;`; ends on `&&`, `||`, `|`, `|&` or a line continuation (`swift test &&`); ends inside a single- or double-quoted run, a `$(` or a backtick run, or after a lone backslash; or whose parentheses outside quoted runs and backslash escapes do not pair, a `)` no earlier `(` opens or a `(` nothing closes.
    ///
    /// Conservative: a parenthesis a `case` pattern owns reads as unbalanced, and so does one quoted inside a substitution, whose quotes are not tracked; a line so read is only left alone.
    public static func isIncomplete(_ command: String) -> Bool {
        let text = runnableText(command).trimmingCharacters(in: .whitespacesAndNewlines)
        let atItsEnds = ["&&", "||", "|", "|&", "\\"].contains { text.hasSuffix($0) } || ["&&", "||", "|", ";"].contains { text.hasPrefix($0) }
        return atItsEnds || leavesAGroupOpenOrUnopened(text)
    }

    /// Whether `text` ends inside a quote or substitution, or its parentheses outside quotes do not pair.
    private static func leavesAGroupOpenOrUnopened(_ text: String) -> Bool {
        var scan = ExecutableTextScan()
        var visible = ""
        for character in text {
            scan.append(character, to: &visible)
        }
        var depth = 0
        for character in visible {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 {
                    return true
                }
            }
        }
        return scan.endsOpen || depth != 0
    }

    /// `command` with its comments taken out: from a `#` that opens a word, outside quotes and substitutions, to the end of its line.
    ///
    /// A comment is not a command and runs nothing, so it can neither be a lookup nor make two commands different: a comment spelling a grep above a script's real work names no search the script makes, and a retry that drops or rewords a comment runs exactly what the refused command ran. A `#` inside a word — `$#`, `${#x}`, `"a"#b` — opens nothing, one inside quotes or behind a backslash is blanked in ``executableText(of:)`` before it is looked for, and inside a substitution, whose quotes that text does not track, none is looked for at all.
    static func withoutComments(_ command: String) -> String {
        guard command.contains("#") else { return command }
        let written = Array(command)
        let text = Array(executableText(of: command))
        guard written.count == text.count else { return command }
        var result = ""
        var substitutionDepth = 0
        var inBacktick = false
        var index = 0
        while index < written.count {
            let character = text[index]
            let previous: Character? = index > 0 ? text[index - 1] : nil
            if character == "(", previous == "$" {
                substitutionDepth += 1
            } else if character == ")", substitutionDepth > 0 {
                substitutionDepth -= 1
            } else if character == "`" {
                inBacktick.toggle()
            }
            let opensAComment = character == "#" && substitutionDepth == 0 && !inBacktick
                && (previous.map { $0.isWhitespace || ";&|(".contains($0) } ?? true)
            guard opensAComment else {
                result.append(written[index])
                index += 1
                continue
            }
            while index < written.count, written[index] != "\n" {
                index += 1
            }
        }
        return result
    }

    /// `command` with every heredoc's body and terminator line taken out, leaving the line that opened it.
    ///
    /// A body is text handed to a command's standard input, not commands, and it is split on newlines like everything else — so a script being written with `cat > check.sh <<'EOF'` had each of its lines judged as a command of its own, and a grep inside it was refused. The body runs from the line after `<<WORD` (quoted or not, and `<<-`, whose terminator may be indented by tabs) up to the line that is the word alone. A here-string, `<<<`, is one word and not a heredoc, and a `<<` inside arithmetic — `$((1<<3))`, `((x <<= 1))` — is a shift. Operators are found in ``executableText(of:)``, so a `<<` inside a quoted argument opens nothing; the word is read from the text as written, since a quoted one is blanked there. A body with no terminator runs to the end.
    ///
    /// The text after each body is scanned as though the body were gone, because the shell reads no quotes inside a body and neither may the scan: an apostrophe in one body, scanned in place, opened a quote that ran on into the lines after it, so the next heredoc's `<<` read as quoted and opened nothing, and its body was judged as commands. The scan resumes from the line the body leaves, in an ``ExecutableTextCursor``, rather than starting over from the top of the command, which made a command's cost its length times the number of heredocs in it.
    static func withoutHeredocBodies(_ command: String) -> String {
        guard command.contains("<<") else { return command }
        let written = Array(command)
        guard written.count == executableText(of: command).count else { return command }
        var cursor = ExecutableTextCursor(written)
        var kept: [Character] = []
        kept.reserveCapacity(written.count)
        var pending: [(word: String, tabs: Bool)] = []
        // Parentheses open inside `$(( … ))` or `(( … ))`, where `<<` is a shift and opens no body.
        var arithmetic = 0
        while let character = cursor.text(at: 0) {
            let index = cursor.position
            if arithmetic > 0 {
                arithmetic += character == "(" ? 1 : character == ")" ? -1 : 0
            } else if character == "(", cursor.text(at: 1) == "(" {
                arithmetic = 1
            }
            let opens = arithmetic == 0 && character == "<" && cursor.text(at: 1) == "<" && cursor.text(at: 2) != "<"
                && cursor.text(at: -1) != "<"
            if opens, let heredoc = heredocWord(in: written, from: index + 2) {
                pending.append(heredoc)
            }
            kept.append(written[index])
            cursor.advance()
            guard written[index] == "\n", character == "\n", !pending.isEmpty else { continue }
            var bodyEnd = cursor.position
            for heredoc in pending {
                bodyEnd = lineIndex(after: heredoc, in: written, from: bodyEnd)
            }
            pending = []
            guard cursor.skip(to: bodyEnd) else { return String(kept + written[bodyEnd...]) }
        }
        return String(kept)
    }

    /// The terminator a heredoc operator introduces, read from just past its `<<`, and whether `<<-` lets it be indented by tabs.
    private static func heredocWord(in written: [Character], from start: Int) -> (word: String, tabs: Bool)? {
        var index = start
        let tabs = index < written.count && written[index] == "-"
        if tabs {
            index += 1
        }
        while index < written.count, written[index] == " " || written[index] == "\t" {
            index += 1
        }
        var word = ""
        var quote: Character?
        while index < written.count {
            let character = written[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    word.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace || ";|&<>()".contains(character) {
                break
            } else if character != "\\" {
                word.append(character)
            }
            index += 1
        }
        return word.isEmpty ? nil : (word, tabs)
    }

    /// The index of the first character after `heredoc`'s terminator line, scanning whole lines from `start`, or the end when no line terminates it.
    private static func lineIndex(after heredoc: (word: String, tabs: Bool), in written: [Character], from start: Int) -> Int {
        var lineStart = start
        while lineStart < written.count {
            var lineEnd = lineStart
            while lineEnd < written.count, written[lineEnd] != "\n" {
                lineEnd += 1
            }
            var line = written[lineStart ..< lineEnd]
            if heredoc.tabs {
                line = line.drop(while: { $0 == "\t" })
            }
            let next = min(lineEnd + 1, written.count)
            if String(line) == heredoc.word {
                return next
            }
            lineStart = next
        }
        return written.count
    }

    /// The statements of `command` paired with the ranges they occupy in it, so a caller can rebuild the line with one of them changed.
    ///
    /// The advisor for `sift run` needs this and nothing else does: its suggestion has to be a complete replacement for the line the caller wrote, and `statements` alone throws away both the separators and the positions. Reconstruction is exact because the splitter only ever *drops* characters — every statement is a verbatim contiguous run of `command`, and they arrive in the order they appear.
    public static func statementRanges(of command: String) -> [(statement: String, range: Range<String.Index>)] {
        var located: [(String, Range<String.Index>)] = []
        var searchStart = command.startIndex
        for statement in statements(of: command) {
            guard let range = command.range(of: statement, options: .literal, range: searchStart ..< command.endIndex) else {
                return []
            }
            located.append((statement, range))
            searchStart = range.upperBound
        }
        return located
    }

    /// The statements the shell runs for `command`: each of its statements, with the statements of every command substitution inside it placed before the statement that holds it.
    ///
    /// A substitution is one value to the statement around it, which is why `statements` and `segments` keep it whole, and it is also a command of its own: `echo "$(sed -n '1,30p' View.swift)"` reads the window it prints, and a lookup inside a substitution is a lookup. So its body is read as statements too — inside double quotes as well as out, since it runs there, and never inside single quotes or behind a backslash, where `$(` is text. A body comes first because it runs first. That is the right order for asking whether any of them reads Swift, and the wrong one for choosing which of them is the lookup, which ``hostStatementsFirst(of:)`` is for.
    ///
    /// Only the reading of lookups asks for this. The advisor for `sift run` rebuilds the caller's line from `statementRanges`, which a statement lifted out of a substitution would break.
    static func executedStatements(of command: String) -> [String] {
        executedStatements(inText: runnableText(command))
    }

    /// The same statements split on pipeline operators, so each piece can be judged on what it acts on.
    static func executedSegments(of command: String) -> [String] {
        executedStatements(of: command).flatMap(pipelineStages)
    }

    /// One statement split at its pipes, `|&` among them: a statement holds no other `&` a redirection does not own, since a lone one ends the statement.
    private static func pipelineStages(of statement: String) -> [String] {
        split(statement, on: { $0 == "|" || $0 == "&" }, stripQuotes: false)
    }

    /// The statements ``executedStatements(of:)`` returns, with every one outside a command substitution ahead of every one inside one, and the same at every depth: a body's own statements ahead of the bodies nested in it.
    ///
    /// The order for a reader choosing *the* lookup a command makes, which is not the order the shell runs them in. The command around a substitution is the one whose effect was asked for, and the substitution only supplies it a word: in `grep -rn Name --include='*.swift' Sources --exclude="$(head -1 Names.swift)"` the lookup is the sweep, and taking the window in its body instead lets a file already open excuse the sweep as a re-read. So a body is the lookup only where no statement outside every substitution reads Swift — `echo "$(sed -n '1,30p' View.swift)"`, whose host only prints. A body is a command line of its own, so the rule applies inside it too: wrapped in an `echo "$(…)"`, that sweep is still the lookup and its window still is not.
    static func hostStatementsFirst(of command: String) -> [String] {
        hostStatementsFirst(inText: runnableText(command))
    }

    /// ``hostStatementsFirst(of:)`` over text whose heredoc bodies are already gone, so a body is never stripped twice.
    private static func hostStatementsFirst(inText text: String) -> [String] {
        let hosts = splitStatements(text)
        return hosts + hosts.flatMap { host in substitutionBodies(in: host).flatMap { hostStatementsFirst(inText: $0) } }
    }

    /// The same statements split on pipeline operators, so each piece can be judged on what it acts on.
    static func hostSegmentsFirst(of command: String) -> [String] {
        hostStatementsFirst(of: command).flatMap(pipelineStages)
    }

    /// ``executedStatements(of:)`` over text whose heredoc bodies are already gone, so a body is never stripped twice.
    private static func executedStatements(inText text: String) -> [String] {
        splitStatements(text).flatMap { statement in
            substitutionBodies(in: statement).flatMap { executedStatements(inText: $0) } + [statement]
        }
    }

    /// One segment split into arguments, with a quoted run kept whole and its quotes removed.
    ///
    /// The opposite choice to `segments`, for the opposite reason: a caller asking for arguments wants values, and a pattern that arrives still wrapped in quotes fails every comparison made against it.
    ///
    /// An unquoted `)` ends a word, as it does to the shell. A subshell written `(cd Kit && sed -n '1,30p' View.swift)` closes against its last argument, and read as part of the word the file is `View.swift)`, which names no Swift file. Quoted or escaped it is a character like any other, so the pattern in `grep -n 'run()' View.swift` keeps it.
    public static func tokens(of segment: String) -> [String] {
        tokens(of: segment, stripQuotes: true)
    }

    /// ``tokens(of:)`` with its quotes kept where `tokens(of:stripQuotes:)` is passed `false`, so a caller can tell a token that was written quoted from one that was not — the shape it is written in, not just its value.
    public static func tokens(of segment: String, stripQuotes: Bool) -> [String] {
        argumentTokens(of: segment).map { stripQuotes ? $0.unquoted : $0.raw }
    }

    /// One segment split into arguments, each carrying both spellings — `raw` with its quotes still on it, `unquoted` with them stripped — built in a single pass so the two arrays a caller reads off them can never drift apart in length.
    ///
    /// A quoted empty argument (`""`) is a real, empty token: what decides whether a piece is kept is whether anything was written for it (its `raw` form, which still holds the quote marks), never whether stripping quotes left it looking empty.
    ///
    /// A newline left in a segment is a blank between words, as it is to the shell: the one a pipeline carries on past, `grep -rn Name . |` ending its line, sits before the next stage's verb.
    static func argumentTokens(of segment: String) -> [(raw: String, unquoted: String)] {
        split(segment, on: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == ")" })
    }

    /// The segment with quoted literal text blanked, leaving what the shell would actually run.
    ///
    /// `segments` keeps quotes so a verb *opening* a quoted run cannot match as a command word, but a verb buried deeper in one — `claude -p "run this: grep -n func Thing.swift"` — still sits between two spaces, and would match: a prompt *about* a grep denied as one, with `where claude` as the suggestion. Blanking the literal characters removes what the surviving quote only marks. A `$(…)` or backtick run stays visible even inside double quotes, because it executes there — a verb inside it is a real invocation. A backslash consumes the character after it (outside single quotes, which have no escapes), so `\"` inside a double-quoted run stays a literal instead of closing the quote and re-exposing the rest of the prose — and that character is blanked outside quotes too, because the shell reads it as a literal there as well: `swift build \> x` passes `>` as an argument and redirects nothing.
    public static func executableText(of segment: String) -> String {
        var result = ""
        var scan = ExecutableTextScan()
        for character in segment {
            scan.append(character, to: &result)
        }
        return result
    }

    /// Splits on the sequencing operators — `;`, `&&`, `||`, a newline, a backgrounding `&` — so each pipeline arrives whole.
    ///
    /// A `||` is a sequence and not two pipes: `sed -n '1,30p' View.swift || true` runs the `true` only where the read failed, and hands it nothing the read printed.
    ///
    /// A newline after a pipe, `|` or `|&`, ends nothing: the shell reads on for the command the pipe feeds, past blank lines and comments, so `echo x |` on one line and `grep -rn Name` on the next are one pipeline. A newline after `&&` or `||` needs no such care, since the operator has already ended the statement.
    private static func splitStatements(_ text: String) -> [String] {
        split(text, on: { ";&\n".contains($0) }, stripQuotes: false, orSeparates: true)
    }

    /// Splits on `separator`, ignoring separators inside single or double quotes, `$(…)` substitutions, and backticks.
    ///
    /// A substitution is one value, not a place where a new command starts: `cat dir/$(ls -t dir | head -1)` split at the inner `|` hands the host segment `-t dir` as arguments, and `-t` followed by anything containing "swift" then reads as ripgrep's language filter — so a `cat` of a JSON file in a directory whose path spells "swift" would be denied as a Swift lookup. Quotes inside a substitution are kept verbatim (they are part of the value), and a `)` inside them does not close it.
    ///
    /// A backslash makes the character after it a literal, outside quotes and inside double ones — single quotes have no escapes. So `find … -exec grep … {} \;` is one command whose last argument is `;`, `a\|b` is one word, `\"` inside a double-quoted run does not close it, and `\$(` opens no substitution. Both characters are kept, so a piece is still a verbatim run of the text.
    ///
    /// The last argument splits at a `||` as well, which no single character marks: the split into statements asks for it, and a split at pipes has `|` among its separators already.
    private static func split(_ text: String, on separator: (Character) -> Bool, stripQuotes: Bool, orSeparates: Bool = false) -> [String] {
        split(text, on: separator, orSeparates: orSeparates).map { stripQuotes ? $0.unquoted : $0.raw }
    }

    /// Splits `text` into pairs, each piece's quotes-intact spelling beside its quotes-stripped one, built in one walk so a caller reading both never sees them disagree on how many tokens there were.
    private static func split(_ text: String, on separator: (Character) -> Bool, orSeparates: Bool = false) -> [(raw: String, unquoted: String)] {
        var pieces: [(raw: String, unquoted: String)] = []
        var raw = ""
        var unquoted = ""
        var quote: Character?
        var substitutionDepth = 0
        var inBacktick = false
        var escaped = false
        // Where the last escaped character sat, so a literal `$` is not taken for the one that opens a substitution.
        var literalOffset: Int?
        // Whether the statement so far ends in a pipe, blanks aside, so a newline after it continues the pipeline.
        var pipeOpen = false
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            let previous = offset > 0 && literalOffset != offset - 1 ? characters[offset - 1] : nil
            let opaque = substitutionDepth > 0 || inBacktick
            let pipeWasOpen = pipeOpen
            if !" \t\n".contains(character) {
                pipeOpen = false
            }
            if escaped {
                escaped = false
                literalOffset = offset
                raw.append(character)
                unquoted.append(character)
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                raw.append(character)
                unquoted.append(character)
                continue
            }
            if let open = quote {
                raw.append(character)
                if character == open {
                    quote = nil
                    if opaque {
                        unquoted.append(character)
                    }
                } else {
                    unquoted.append(character)
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                raw.append(character)
                if opaque {
                    unquoted.append(character)
                }
            case "(" where previous == "$":
                substitutionDepth += 1
                raw.append(character)
                unquoted.append(character)
            case ")" where substitutionDepth > 0:
                substitutionDepth -= 1
                raw.append(character)
                unquoted.append(character)
            case "`":
                inBacktick.toggle()
                raw.append(character)
                unquoted.append(character)
            case "\n" where orSeparates && pipeWasOpen, "&" where orSeparates && pipeWasOpen && previous == "|":
                // A pipe's command is still to come after a newline, and `|&` is one operator, piping both output streams.
                pipeOpen = true
                raw.append(character)
                unquoted.append(character)
            case _ where separator(character) && !opaque && !joinsARedirection(at: offset, in: characters),
                 _ where orSeparates && !opaque && isHalfOfAnOr(at: offset, in: characters, literalAt: literalOffset):
                if !raw.isEmpty {
                    pieces.append((raw, unquoted))
                    raw = ""
                    unquoted = ""
                }
            default:
                if orSeparates, character == "|", !opaque, !joinsARedirection(at: offset, in: characters) {
                    pipeOpen = true
                }
                raw.append(character)
                unquoted.append(character)
            }
        }
        if !raw.isEmpty {
            pieces.append((raw, unquoted))
        }
        return pieces
    }

    /// The body of every outermost command substitution in `text` — `$(…)` and backticks — read where the shell would run it: outside single quotes and escapes, inside double quotes or out.
    ///
    /// `$((…))` is arithmetic rather than a command and has no body. A substitution nested inside a body is found when that body is read in turn.
    private static func substitutionBodies(in text: String) -> [String] {
        let characters = Array(text)
        var bodies: [String] = []
        var inDoubleQuotes = false
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "'" where !inDoubleQuotes:
                index = characters[(index + 1)...].firstIndex(of: "'") ?? characters.count
            case "\"":
                inDoubleQuotes.toggle()
            case "$" where index + 1 < characters.count && characters[index + 1] == "("
                && (index + 2 == characters.count || characters[index + 2] != "("):
                let end = closingParenthesis(in: characters, from: index + 2)
                bodies.append(String(characters[(index + 2) ..< end]))
                index = end
            case "`":
                let end = closingBacktick(in: characters, from: index + 1)
                bodies.append(String(characters[(index + 1) ..< end]))
                index = end
            default:
                break
            }
            index += 1
        }
        return bodies
    }

    /// The index of the `)` closing a substitution whose body starts at `start`, or the end of `characters` when nothing closes it.
    ///
    /// A parenthesis inside quotes, behind a backslash or inside a nested substitution is not the one, and a subshell's pair inside the body is matched rather than taken for the close.
    private static func closingParenthesis(in characters: [Character], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "'":
                index = characters[(index + 1)...].firstIndex(of: "'") ?? characters.count
            case "\"":
                index = closingDoubleQuote(in: characters, from: index + 1)
            case "`":
                index = closingBacktick(in: characters, from: index + 1)
            case "(":
                depth += 1
            case ")":
                guard depth > 0 else { return index }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return characters.count
    }

    /// The index of the `"` closing a double-quoted run that starts at `start`, stepping over the substitutions that run inside it.
    private static func closingDoubleQuote(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "\"":
                return index
            case "$" where index + 1 < characters.count && characters[index + 1] == "(":
                index = closingParenthesis(in: characters, from: index + 2)
            case "`":
                index = closingBacktick(in: characters, from: index + 1)
            default:
                break
            }
            index += 1
        }
        return characters.count
    }

    /// The index of the backtick closing a substitution whose body starts at `start`: the first one no backslash escapes, since backticks do not nest unescaped.
    private static func closingBacktick(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "`" {
                return index
            }
            index += 1
        }
        return characters.count
    }

    /// Whether this `|` is one half of a `||`, which runs the next command only where this one failed rather than piping into it.
    ///
    /// A `|` escaped by a backslash is a literal, and pairs with nothing.
    private static func isHalfOfAnOr(at offset: Int, in characters: [Character], literalAt literal: Int?) -> Bool {
        guard characters[offset] == "|" else { return false }
        let before = offset > 0 && literal != offset - 1 && characters[offset - 1] == "|"
        let after = offset + 1 < characters.count && characters[offset + 1] == "|"
        return before || after
    }

    /// Whether this `&` or `|` belongs to a redirection rather than separating one command from the next.
    ///
    /// `2>&1`, `&> log` and `>| log` are single tokens to the shell, and splitting inside them is worse than merely inaccurate: the piece ends in a bare `>` that names no destination while the destination lands in the piece after it. That is two misreadings at once — a stream merge looks like a redirect to somewhere, and a genuine redirect looks like a plain command, or, for `>|`, like a pipeline — and all three spellings turn up in an agent's Bash calls.
    ///
    /// Everything else keeps its meaning: `&&` is two ampersands neither preceded nor followed by `>`, a trailing `&` backgrounds the command as it always did, and a `|` neither directly after `>` nor beside another `|` is a pipe.
    private static func joinsARedirection(at offset: Int, in characters: [Character]) -> Bool {
        let followsARedirect = offset > 0 && characters[offset - 1] == ">"
        return switch characters[offset] {
        case "|": followsARedirect
        case "&": followsARedirect || (offset + 1 < characters.count && characters[offset + 1] == ">")
        default: false
        }
    }
}
