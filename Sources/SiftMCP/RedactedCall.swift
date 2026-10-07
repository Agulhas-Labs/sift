//
// Copyright © Agulhas Labs
//

import Foundation

extension TranscriptAudit {
    /// A refused call, redacted the way a file or symbol name is redacted everywhere else in this report.
    ///
    /// Redaction is an allowlist, not a denylist: a shell command carries far more shapes than any list of dangerous substrings can enumerate — a compound pipeline, a word glued to `;` or `)`, a quoted phrase with a space in it.
    ///
    /// So in redacted mode nothing survives unless this file names it safe — command words, flags, shell operators, integers, and the call's own leading tool label — and every other word, whole quoted string, path or identifier is replaced by its pseudonym from `Redactor`.
    struct CallRedaction {
        /// Command and keyword words safe to print unredacted: none of them names a file, a symbol, or a project, in any repository this report could be measuring.
        ///
        /// The three device paths name the machine's own streams, never anything about a repository, so a redirection to one of them is exempt too.
        static let safeWords: Set<String> = [
            "grep", "egrep", "fgrep", "rg", "cat", "head", "tail", "sed", "awk", "cut", "sort", "uniq",
            "wc", "ls", "find", "xargs", "echo", "printf", "git", "show", "log", "diff", "blame",
            "for", "do", "done", "in", "if", "then", "fi", "while", "test", "tr", "nl", "cd",
            "true", "false", "sift", "swift", "xcodebuild", "gh",
            "/dev/null", "/dev/stdout", "/dev/stderr",
        ]

        /// Shell control tokens that shape a command rather than name anything in it — kept verbatim wherever they land, whitespace-delimited or glued to the word beside them.
        ///
        /// Checked longest first, so `&&`/`||`/`>>` never fall apart into two single-character operators. An fd-prefixed redirection (`2>&1`, `2>secret.log`) is not in this table — the tokenizer below re-glues one back into a single token, and ``isRedirectionDup(_:)``/``redirectionFileForm(_:)`` read it apart again at redaction time.
        static let shellOperators = ["||", "&&", ">>", ";", "|", "&", ">", "<", "(", ")", "{", "}", "`"]

        /// The keywords and operators after which a collapsed newline is a single space rather than ` ; ` — the line before them was still building one command, not ending it.
        private static let lineContinuations: Set<String> = ["do", "then", "else"]
        static let lineContinuationOperators = ["||", "&&", ";", "|", "{"]

        /// `key=` prefixes that redact their value unconditionally — the `Grep`/`Glob` tools' own display fields, never a general shell assignment.
        static let keyedOperands: Set<String> = ["pattern", "path", "glob", "type"]

        /// `text`, redacted for sharing: every word that is not on the allowlist above is replaced by its pseudonym.
        ///
        /// The call's first word is always its tool label (`Read`, `Grep`, `Glob`, `Bash:`) and is always kept, and a multi-line command collapses to one line first, so it reads the same way `--unredact` prints it. The word after a flag that takes one (`grep -e`, `grep -ie`, `git -C`) is that flag's value, as ``shape(of:)`` reads it, so one opening with a dash is pseudonymised as an operand, never kept as a flag cluster.
        static func redactedCall(_ text: String, by redactor: Redactor) -> String {
            let tokens = mergingRedirections(tokenized(collapsingNewlines(text)))
            guard let label = tokens.first else { return "" }
            var afterBareDoubleDash = false
            var expectsCommand = !toolLabels.contains(label)
            var command = ""
            var awaitingFlagValue = false
            var rest: [String] = []
            for token in tokens.dropFirst() {
                if shellOperators.contains(token) {
                    afterBareDoubleDash = false
                    rest.append(token)
                    if ShapeTokenReader.endsStatement(token) {
                        expectsCommand = true
                        command = ""
                        awaitingFlagValue = false
                    }
                } else if afterBareDoubleDash {
                    rest.append(redactedOperand(token, forcingFile: false, by: redactor))
                } else if token == "--" {
                    afterBareDoubleDash = true
                    rest.append(token)
                } else if expectsCommand {
                    expectsCommand = false
                    command = token
                    rest.append(redactedToken(token, command: command, by: redactor))
                } else if awaitingFlagValue {
                    awaitingFlagValue = false
                    let isFlagLike = looksLikeFlag(ShapeTokenReader.flagWord(of: token))
                    rest.append(isFlagLike ? redactedOperand(token, forcingFile: false, by: redactor) : redactedToken(token, command: command, by: redactor))
                } else {
                    awaitingFlagValue = ShapeTokenReader.flagTakesValue(token, for: command) != nil
                    rest.append(redactedToken(token, command: command, by: redactor))
                }
            }
            return ([label] + rest).joined(separator: " ")
        }

        /// `text` with its newlines collapsed for a one-line display — used in both modes, so `--unredact` reads a multi-line command the same shape as the redacted report does.
        ///
        /// Most newlines become ` ; `, so a multi-line command's separate commands still read as separate rather than running together. A newline that was really just how the *same* command wrapped becomes a single space instead: one after a line ending in `|`, `||`, `&&`, `;` or `{`, one after a line ending in the keyword `do`, `then` or `else`, one after a backslash line continuation (the backslash itself is dropped), and any newline that falls inside an open quote. A run of blank lines between two commands still gives one separator, and a leading or trailing run of newlines gives none.
        static func collapsingNewlines(_ text: String) -> String {
            var result = ""
            var openQuote: Character?
            for line in text.components(separatedBy: "\n") {
                let wasInsideQuote = openQuote != nil
                for character in line {
                    if let quote = openQuote {
                        if character == quote {
                            openQuote = nil
                        }
                    } else if character == "\"" || character == "'" {
                        openQuote = character
                    }
                }
                let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty

                if result.isEmpty {
                    if !isBlank {
                        result = line
                    }
                } else if wasInsideQuote {
                    result += " " + line
                } else if isBlank {
                    continue
                } else if result.hasSuffix("\\") {
                    result.removeLast()
                    result += " " + line
                } else if joinsWithSpace(after: result) {
                    result += " " + line
                } else {
                    result += " ; " + line
                }
            }
            return result
        }

        /// Whether a newline right after `trailing` — the line collapsed so far — is really just how one command wrapped, and so collapses to a space rather than ` ; `.
        private static func joinsWithSpace(after trailing: String) -> Bool {
            if lineContinuationOperators.contains(where: trailing.hasSuffix) {
                return true
            }
            guard let lastWord = trailing.split(whereSeparator: \.isWhitespace).last else {
                return false
            }
            return lineContinuations.contains(String(lastWord))
        }

        /// `text` split into words on whitespace and shell operators, except inside a single- or double-quoted span — which keeps a quoted phrase together as one token even when it holds a space, a pipe, or an escaped alternation — and with an operator glued to the word beside it (`devkit-hooks.conf;`) split into its own token.
        private static func tokenized(_ text: String) -> [String] {
            var tokens: [String] = []
            var buffer = ""
            var openQuote: Character?
            let characters = Array(text)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if let quote = openQuote {
                    buffer.append(character)
                    if character == quote {
                        openQuote = nil
                    }
                    index += 1
                    continue
                }
                if character == "\"" || character == "'" {
                    openQuote = character
                    buffer.append(character)
                    index += 1
                    continue
                }
                if character.isWhitespace {
                    if !buffer.isEmpty {
                        tokens.append(buffer)
                        buffer = ""
                    }
                    index += 1
                    continue
                }
                if let matched = shellOperators.first(where: { characters[index...].starts(with: $0) }) {
                    if !buffer.isEmpty {
                        tokens.append(buffer)
                        buffer = ""
                    }
                    tokens.append(matched)
                    index += matched.count
                    continue
                }
                buffer.append(character)
                index += 1
            }
            if !buffer.isEmpty {
                tokens.append(buffer)
            }
            return tokens
        }

        /// `tokens`, with an fd-prefixed redirection the tokenizer above split apart — `["2", ">", "secret.log"]`, or `["2", ">", "&", "1"]` for the dup form — glued back into the single token it renders as, so `redactedToken` sees `"2>secret.log"` or `"2>&1"` rather than three unrelated words.
        ///
        /// Detected purely from adjacency in the token stream: an optional bare integer, then `>`, `>>`, or the standalone tokens `&` `>` (for `&>`), then either `&` plus a bare integer or `-` (the dup form), or the very next token as its glued operand (the file form).
        private static func mergingRedirections(_ tokens: [String]) -> [String] {
            var result: [String] = []
            var index = 0
            while index < tokens.count {
                if let (merged, consumed) = redirection(in: tokens, at: index) {
                    result.append(merged)
                    index += consumed
                } else {
                    result.append(tokens[index])
                    index += 1
                }
            }
            return result
        }

        /// The redirection starting at `tokens[index]`, if there is one, and how many tokens it consumed.
        private static func redirection(in tokens: [String], at index: Int) -> (token: String, consumed: Int)? {
            var cursor = index
            var fdPrefix = ""
            if isBareInteger(tokens[cursor]) {
                fdPrefix = tokens[cursor]
                cursor += 1
                guard cursor < tokens.count else { return nil }
            }

            let redirectionOperator: String
            if tokens[cursor] == ">>" {
                redirectionOperator = fdPrefix + ">>"
                cursor += 1
            } else if tokens[cursor] == ">" {
                redirectionOperator = fdPrefix + ">"
                cursor += 1
            } else if fdPrefix.isEmpty, tokens[cursor] == "&", cursor + 1 < tokens.count, tokens[cursor + 1] == ">" {
                redirectionOperator = "&>"
                cursor += 2
            } else {
                return nil
            }
            guard cursor < tokens.count else { return nil }

            // The dup form: `&` then a bare integer or `-` — `2>&1`, `>&-`.
            if tokens[cursor] == "&", cursor + 1 < tokens.count {
                let target = tokens[cursor + 1]
                if target == "-" || isBareInteger(target) {
                    return (redirectionOperator + "&" + target, cursor + 2 - index)
                }
            }

            // The file form: the very next token is the operand, glued to the operator with no space.
            return (redirectionOperator + tokens[cursor], cursor + 1 - index)
        }

        /// One token of a refused call's text, other than its leading label, redacted per the allowlist, its flags by the rule `command` — its statement's own command word — keeps them by (see ``redactedFlag(_:for:)``), and a redirection's target by no command's rule, as ``shape(of:)`` reads it.
        private static func redactedToken(_ token: String, command: String, by redactor: Redactor) -> String {
            if shellOperators.contains(token) {
                return token
            }
            if isRedirectionDup(token) {
                return token
            }
            if let split = redirectionFileForm(token) {
                return split.operatorPart + redactedToken(split.operand, command: "", by: redactor)
            }
            if let equals = token.firstIndex(of: "=") {
                let key = String(token[..<equals])
                let value = String(token[token.index(after: equals)...])
                if keyedOperands.contains(key) {
                    return "\(key)=" + redactedOperand(value, forcingFile: key == "path" || key == "glob", by: redactor)
                }
                if looksLikeFlag(key) {
                    return redactedFlag(key, for: command) + "=" + redactedOperand(value, forcingFile: false, by: redactor)
                }
            }
            if looksLikeFlag(token) {
                return redactedFlag(token, for: command)
            }
            if isQuoted(token) {
                return redactedOperand(token, forcingFile: false, by: redactor)
            }
            if let colon = token.lastIndex(of: ":") {
                let revision = String(token[..<colon])
                let path = String(token[token.index(after: colon)...])
                if isPathLike(path) {
                    let keptRevision = isHEADRelative(revision) ? revision : redactor.symbol(revision)
                    return keptRevision + ":" + redactor.file(path)
                }
            }
            if safeWords.contains(token) || token == "---" || isBareInteger(token) {
                return token
            }
            return redactedOperand(token, forcingFile: false, by: redactor)
        }

        /// `operand` — a bare word, or a quoted phrase — redacted as a file when the caller already knows it names one, or when it looks like a path or file name once unquoted; redacted as a symbol otherwise.
        private static func redactedOperand(_ operand: String, forcingFile: Bool, by redactor: Redactor) -> String {
            let bare = unquoted(operand)
            return forcingFile || isPathLike(bare) ? redactor.file(bare) : redactor.symbol(bare)
        }

        /// `word` with one layer of surrounding matching quotes stripped.
        static func unquoted(_ word: String) -> String {
            guard isQuoted(word) else { return word }
            return String(word.dropFirst().dropLast())
        }

        /// Whether `word` is a single quoted span from end to end — the whole word, not merely containing a quote.
        static func isQuoted(_ word: String) -> Bool {
            guard let first = word.first, let last = word.last, word.count >= 2 else { return false }
            return first == last && (first == "\"" || first == "'")
        }

        /// Whether `word` spells a path or a file name: a `/` anywhere in it, or an extension — a dot, a letter, then up to nine more letters or digits — closing it out.
        ///
        /// A backslash rules this out first — it is never part of a real path in a call's display text, only a regex escape inside a pattern (`'/\.build/'`, excluding a directory by name). Reading that as a path would hand `Redactor.file` a fake basename ahead of the dot (`\`) and a real word after it, which comes back out as that word's own plain-text "extension".
        static func isPathLike(_ word: String) -> Bool {
            guard !word.contains("\\") else { return false }
            if word.contains("/") {
                return true
            }
            guard let dot = word.lastIndex(of: ".") else { return false }
            let extensionPart = word[word.index(after: dot)...]
            guard let first = extensionPart.first, first.isASCII, first.isLetter, extensionPart.count <= 10 else { return false }
            return extensionPart.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        /// Whether `token` is a flag: one or two leading dashes, then a run of letters, digits and hyphens — `-n`, `--include`, `-c1-240` all match; `--` alone and `--include=…` (the `=` stops the run) don't.
        static func looksLikeFlag(_ token: String) -> Bool {
            var rest = Substring(token)
            guard rest.first == "-" else { return false }
            rest.removeFirst()
            if rest.first == "-" {
                rest.removeFirst()
            }
            guard let first = rest.first, first.isASCII, first.isLetter || first.isNumber else { return false }
            return rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }

        /// `token` — already known to look like a flag — split into its leading dashes and the letters/digits after them.
        static func flagBody(_ token: String) -> (dashes: String, rest: Substring) {
            var rest = Substring(token)
            var dashes = ""
            while rest.first == "-" {
                dashes.append("-")
                rest.removeFirst()
            }
            return (dashes, rest)
        }

        /// `token` — already known to look like a flag — redacted by the rule `shape(of:)` spells a flag by, keyed on `command`, its statement's own command word.
        ///
        /// A double-dash flag survives only when it is on one of ``ShapeFlagVocabulary``'s closed lists, and reads `--<text>` otherwise. A single-dash flag survives only as far as ``ShapeFlagVocabulary/clusterReading(_:for:)`` keeps it as `command`'s own flags, and whatever is glued after that reads `<text>` (`grep -xyoung` reads `-x<text>`, `ls -ladepot` reads `-la<text>`), or stays as written when no letter is left in it (`-A12`, `cut -c1-240`, `head -40`).
        private static func redactedFlag(_ token: String, for command: String) -> String {
            let (dashes, rest) = flagBody(token)
            guard dashes == "-" else {
                return ShapeFlagVocabulary.isListedLongFlag(token) ? token : dashes + "<text>"
            }
            let kept = ShapeFlagVocabulary.clusterReading(rest, for: command).kept
            guard kept < rest.count else { return token }
            let tail = rest.dropFirst(kept)
            return dashes + rest.prefix(kept) + (tail.contains(where: \.isLetter) ? "<text>" : tail)
        }

        /// Whether `token` is nothing but ASCII digits.
        static func isBareInteger(_ token: String) -> Bool {
            !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
        }

        /// Whether `token` is a whole `N>&M` or `N>&-` redirection — a file descriptor pointed at another one, never at a file — so it is kept verbatim rather than redacted.
        static func isRedirectionDup(_ token: String) -> Bool {
            guard let ampersand = token.lastIndex(of: "&"), ampersand > token.startIndex else { return false }
            let head = token[token.startIndex ..< ampersand]
            let tail = token[token.index(after: ampersand)...]
            guard head.hasSuffix(">") else { return false }
            let descriptor = head.dropLast()
            guard descriptor.isEmpty || descriptor.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            return tail == "-" || (!tail.isEmpty && tail.allSatisfy { $0.isASCII && $0.isNumber })
        }

        /// `token` split into its redirection operator — kept verbatim — and its operand, redacted the same as any other token, if it is a glued `N>path`, `N>>path` or `&>path` redirection.
        ///
        /// `nil` for anything else.
        static func redirectionFileForm(_ token: String) -> (operatorPart: String, operand: String)? {
            if token.hasPrefix("&>") {
                let operand = String(token.dropFirst(2))
                return operand.isEmpty ? nil : ("&>", operand)
            }
            var digits = ""
            var rest = Substring(token)
            while let first = rest.first, first.isASCII, first.isNumber {
                digits.append(first)
                rest.removeFirst()
            }
            if rest.hasPrefix(">>") {
                let operand = rest.dropFirst(2)
                return operand.isEmpty ? nil : (digits + ">>", String(operand))
            }
            if rest.hasPrefix(">") {
                let operand = rest.dropFirst(1)
                return operand.isEmpty ? nil : (digits + ">", String(operand))
            }
            return nil
        }

        /// Whether `revision` is `HEAD` or one of its relative forms (`HEAD~2`, `HEAD^^`) — specific enough to be worth showing, and never identifying on their own.
        static func isHEADRelative(_ revision: String) -> Bool {
            if revision == "HEAD" {
                return true
            }
            if revision.hasPrefix("HEAD~") {
                let count = revision.dropFirst("HEAD~".count)
                return !count.isEmpty && count.allSatisfy { $0.isASCII && $0.isNumber }
            }
            if revision.hasPrefix("HEAD^") {
                let carets = revision.dropFirst("HEAD^".count)
                return carets.allSatisfy { $0 == "^" }
            }
            return false
        }
    }
}

extension TranscriptAudit.CallRedaction {
    /// The tool labels a call's text can open with, kept as the first word of its shape.
    private static let toolLabels: Set<String> = ["Read", "Grep", "Glob"]

    /// Commands whose own first non-flag operand is an address or a script, never a file however path-like it reads: a `sed` line address (already read as `<range>`) or pattern-bearing address, or an `awk` program.
    private static let addressCommands: Set<String> = ["sed", "awk"]

    /// The known CLI tools this shape keeps a subcommand verb for, and the closed vocabulary its own subcommand positions take, first position first — a word that reads as a subcommand only right where one is expected, never merely because it appears somewhere in the line.
    ///
    /// A tool with two levels (nested the way a `gh` call is — its noun, then its verb) lists a set for each; every other tool here has one. The positions run straight on from the tool word: the first flag closes them, so a flag's own value (`git -C <dir>`, `xcodebuild -scheme <name>`) is never read as a verb, and a verb written after a flag reads as an operand instead.
    static let subcommandsByTool: [String: [Set<String>]] = [
        "swift": [["build", "run", "test", "package"]],
        "sift": [[
            "digest", "where", "search", "strings", "run", "test", "affected", "flakes",
            "report", "usage", "audit", "servers", "status", "similar", "dupes", "help", "build",
        ]],
        "xcodebuild": [[
            "build", "test", "archive", "clean", "analyze", "install", "installsrc",
            "build-for-testing", "test-without-building",
        ]],
        "git": [[
            "log", "diff", "blame", "show", "status", "commit", "add", "push", "pull", "fetch",
            "checkout", "branch", "merge", "rebase", "stash", "clone", "tag", "reset",
        ]],
        "gh": [
            ["issue", "pr", "repo", "release", "workflow", "gist", "auth", "api", "browse", "run"],
            ["view", "create", "list", "edit", "close", "merge", "checkout", "status", "clone", "diff", "comment"],
        ],
    ]

    /// The first-level words of a two-level tool that take a verb after them; any other one (`gh api`, `gh browse`) takes a path or an endpoint, so the positions close right after it.
    private static let nounsTakingVerbByTool: [String: Set<String>] = [
        "gh": ["issue", "pr", "repo", "release", "workflow", "gist", "run", "auth"],
    ]

    /// `text` reduced to its shape: command words, flags and shell operators as written, and every operand replaced by the kind of thing it is, so calls that differ only in what they name read the same.
    ///
    /// Words are kept by the same allowlist ``redactedCall(_:by:)`` keeps them by, so a shape names no path, symbol or text: a digit in a flag reads `<n>` too, a leading `Read`, `Grep` or `Glob` tool label is kept, a known tool's own subcommand verb survives right after it, a `grep`/`egrep`/`rg` pattern or a `sed`/`awk` address or script reads `<pattern>`, and a run of four or more like operands collapses to one with its count, so the operand count survives and the line stays short.
    static func shape(of text: String) -> String {
        let tokens = mergingRedirections(tokenized(collapsingNewlines(text)))
        var afterBareDoubleDash = false
        var expectsCommand = true
        var command = ""
        var subcommandLevels: [Set<String>] = []
        var subcommandPosition = 0
        var awaitingPositionalPattern = false
        var awaitingFlagPattern = false
        var awaitingFlagValue = false
        var shaped: [String] = []
        for (index, token) in tokens.enumerated() {
            if index == 0, toolLabels.contains(token) {
                shaped.append(token)
                expectsCommand = false
            } else if shellOperators.contains(token) {
                afterBareDoubleDash = false
                shaped.append(token)
                if ShapeTokenReader.endsStatement(token) {
                    expectsCommand = true
                    command = ""
                    subcommandLevels = []
                    subcommandPosition = 0
                    awaitingPositionalPattern = false
                    awaitingFlagPattern = false
                    awaitingFlagValue = false
                }
            } else if afterBareDoubleDash {
                shaped.append(ShapeTokenReader.placeholder(for: token))
            } else if token == "--" {
                afterBareDoubleDash = true
                shaped.append(token)
            } else if expectsCommand {
                expectsCommand = false
                command = token
                subcommandLevels = subcommandsByTool[token] ?? []
                subcommandPosition = 0
                awaitingPositionalPattern = (patternCommands.contains(token) || addressCommands.contains(token))
                    && !ShapeTokenReader.patternGivenByFlag(to: token, in: tokens, after: index)
                awaitingFlagPattern = false
                awaitingFlagValue = false
                shaped.append(ShapeTokenReader.shapedToken(token))
            } else if awaitingFlagPattern || awaitingFlagValue {
                shaped.append(awaitingFlagPattern ? ShapeTokenReader.shapedToken(token, asPattern: true) : ShapeTokenReader.placeholder(for: token))
                awaitingFlagPattern = false
                awaitingFlagValue = false
            } else if subcommandPosition < subcommandLevels.count {
                if !looksLikeFlag(token), subcommandLevels[subcommandPosition].contains(token) {
                    shaped.append(token)
                    subcommandPosition += 1
                    if subcommandPosition < subcommandLevels.count, nounsTakingVerbByTool[command]?.contains(token) != true {
                        subcommandPosition = subcommandLevels.count
                    }
                } else if ShapeFlagVocabulary.valueFlagsByCommand[command]?.contains(token) == true {
                    awaitingFlagValue = true
                    shaped.append(ShapeTokenReader.shapedToken(token, command: command))
                } else {
                    subcommandPosition = subcommandLevels.count
                    shaped.append(ShapeTokenReader.shapedToken(token, command: command, closesSubcommandTracking: true))
                }
            } else if command == "git", token == "-C" {
                // Right after its own subcommand, git's `-C` means detect copies and takes no value — only
                // right after `git` itself, before any subcommand, does it take the directory it is run in.
                shaped.append(ShapeTokenReader.shapedToken(token, command: command))
            } else if command == "sed", token == "-i", !ShapeTokenReader.sedInPlaceTakesSpacedValue(tokens, at: index) {
                // A spaced `-i` takes the next word as a macOS backup suffix only when that word could be
                // one; a flag or a non-empty quoted script right after it means the GNU form, no suffix.
                shaped.append(ShapeTokenReader.shapedToken(token, command: command))
            } else if let takesPattern = ShapeTokenReader.flagTakesValue(token, for: command) {
                awaitingFlagPattern = takesPattern
                awaitingFlagValue = !takesPattern
                shaped.append(ShapeTokenReader.shapedToken(token, command: command))
            } else if awaitingPositionalPattern, !looksLikeFlag(ShapeTokenReader.flagWord(of: token)), !ShapeTokenReader.opensWithKnownFlagLetter(token, for: command), !ShapeTokenReader.isRedirection(token) {
                awaitingPositionalPattern = false
                shaped.append(ShapeTokenReader.shapedToken(token, asPattern: true))
            } else {
                shaped.append(ShapeTokenReader.shapedToken(token, command: command))
            }
        }
        var collapsed: [String] = []
        var index = 0
        while index < shaped.count {
            var end = index + 1
            while end < shaped.count, shaped[end] == shaped[index] {
                end += 1
            }
            let run = end - index
            if run >= 4, shaped[index].hasPrefix("<"), shaped[index].hasSuffix(">"), shaped[index].count > 2 {
                collapsed.append("\(shaped[index])×\(run)")
            } else {
                collapsed.append(contentsOf: shaped[index ..< end])
            }
            index = end
        }
        return collapsed.joined(separator: " ")
    }
}

extension TranscriptAudit.CallRedaction {
    /// Words and grouping tokens that can open a statement, or a clause inside one, without being its command: a loop or branch keyword, a subshell or group brace, a negation.
    ///
    /// `for`, `select`, `case` and `function` are not here — none of them opens a command at all (`for x in a b` names a variable and a list, never one to run; `case $x in a)` opens a pattern clause, not a command); ``structure(of:)`` skips their own clause words directly instead, and reads a `for`/`select` list's words for files the same as any other operand.
    private static let leadingNonCommands: Set<String> = [
        "if", "do", "then", "else", "elif", "while", "until", "done", "fi", "esac", "(", ")", "{", "}", "!",
    ]

    /// Commands whose first non-option operand — or the operand right after `-e` — is a search pattern, never a file, however path-like it reads.
    private static let patternCommands: Set<String> = ["grep", "egrep", "rg"]

    /// Words that never run anything themselves, only carry their own flags ahead of the real command they precede — `time -p grep …` and `command grep …` both read as `grep`, their own flag skipped right along with the word.
    private static let commandPrefixWords: Set<String> = ["time", "command"]

    /// `key=` prefixes whose value is a pattern or glob, never a file: the `Grep`/`Glob` tools' own pattern fields, and a `grep`-style include/exclude glob.
    private static let patternKeys: Set<String> = ["pattern", "glob", "type", "include", "exclude"]

    /// `text`'s structure, on one line naming no path, symbol or text: how many statements it holds, the command words that open them, how many distinct files it names, and whether it pipes or also calls sift.
    ///
    /// Statements split the way ``ShellSyntax`` splits them for every other reading of a call — at `;`, `&`, `||` and a line break, never inside a quote, a `$(…)` or backtick substitution, or behind the backslash that makes `find … -exec … {} \; -print` one command whose last `-exec` argument is `;` — and a heredoc's body is gone before the split ever sees it, so a script piped to `python3 - <<EOF` is the one statement it is, not one per body line. A pipe keeps its stages in one statement and marks the line `piped`. An opening word is printed as written only where the redaction allowlist or the tool labels hold it, and as `other` otherwise; `sift`, bare or reached by a path, is left out of the words and marks the line `with sift` instead; a `for`, `if`, `while` or `time` ahead of it is skipped rather than read as the command, the way an `LC_ALL=C` assignment already is — `for`'s own variable name and `in` are skipped too, but each word of its list is read for a file the same as any other operand. A redirect straight after a closing `done` or `fi` belongs to the compound it closes, not to a new statement, and opens none. A file is a path-like operand, counted once however often it is named — never a tool call's `pattern=`/`glob=`/`type=` field, an `--include=`/`--exclude=` value, a token holding a glob character (`*?[`), or a search command's own pattern slot (`grep`/`egrep`/`rg`'s first bare operand, or the operand right after `-e`).
    static func structure(of text: String) -> String {
        var statements = 0
        var words: Set<String> = []
        var files: Set<String> = []
        var piped = false
        var withSift = false
        for entry in statementsGroupingArithmeticParens(of: text) {
            let statementText = entry.text
            // A merged fragment's own `;` was never a pipeline boundary — it was a bare `((…))`'s inner separator, glued back together above — so it is read as the one segment it is rather than re-split.
            let segments = entry.merged ? [statementText] : ShellSyntax.segments(of: statementText)
            if segments.count > 1 {
                piped = true
            }
            for (segmentIndex, segmentText) in segments.enumerated() {
                let isFirstSegment = segmentIndex == 0
                var expectsCommand = true
                var clauseTokensToSkip = 0
                var justClosedCompound = false
                var awaitingRedirectTarget = false
                var awaitingPatternOperand = false
                var awaitingDashEOperand = false
                var skippingPrefixFlags = false
                let tokens = mergingRedirections(tokenized(collapsingNewlines(segmentText)))
                var tokenIndex = 0
                while tokenIndex < tokens.count {
                    let token = tokens[tokenIndex]
                    defer { tokenIndex += 1 }
                    if awaitingRedirectTarget {
                        awaitingRedirectTarget = false
                        continue
                    } else if justClosedCompound, token == "<" {
                        awaitingRedirectTarget = true
                        continue
                    } else if justClosedCompound, isRedirectionDup(token) || redirectionFileForm(token) != nil {
                        justClosedCompound = false
                        continue
                    } else if clauseTokensToSkip > 0 {
                        clauseTokensToSkip -= 1
                        continue
                    } else if skippingPrefixFlags, looksLikeFlag(token) {
                        continue
                    } else if expectsCommand {
                        justClosedCompound = false
                        skippingPrefixFlags = false
                        if token == "for" || token == "select" {
                            expectsCommand = false
                            clauseTokensToSkip = 2
                            continue
                        }
                        if token == "case" {
                            // `case $x in` — the subject and `in`, so the next word read is the first pattern label.
                            clauseTokensToSkip = 2
                            continue
                        }
                        if token == "function" {
                            // `function f {` — its name, so the brace right after is what's left to skip.
                            clauseTokensToSkip = 1
                            continue
                        }
                        guard !leadingNonCommands.contains(token), !isAssignment(token), !commandPrefixWords.contains(token) else {
                            if token == "done" || token == "fi" || token == "esac" {
                                justClosedCompound = true
                            }
                            if commandPrefixWords.contains(token) {
                                skippingPrefixFlags = true
                            }
                            continue
                        }
                        let nextToken = tokenIndex + 1 < tokens.count ? tokens[tokenIndex + 1] : nil
                        let nextNextToken = tokenIndex + 2 < tokens.count ? tokens[tokenIndex + 2] : nil
                        guard nextToken != ")", !(nextToken == "(" && nextNextToken == ")") else {
                            // A case pattern label (`a)`) or a bare function's name ahead of its `()` — neither is itself a command.
                            continue
                        }
                        expectsCommand = false
                        let openingWord = token.split(separator: "/").last.map(String.init) ?? token
                        if openingWord == "sift" {
                            withSift = true
                        } else if isFirstSegment {
                            words.insert(safeWords.contains(token) || toolLabels.contains(token) ? token : "other")
                        }
                        if isFirstSegment {
                            statements += 1
                        }
                        awaitingPatternOperand = patternCommands.contains(openingWord)
                        awaitingDashEOperand = false
                    } else if awaitingDashEOperand {
                        awaitingDashEOperand = false
                        awaitingPatternOperand = false
                    } else if token == "-e" {
                        awaitingDashEOperand = true
                    } else if awaitingPatternOperand, !looksLikeFlag(token) {
                        awaitingPatternOperand = false
                    } else if let file = namedFile(token) {
                        files.insert(file)
                    }
                }
            }
        }
        var parts = [
            statements >= 3 ? "3+ statements" : statements == 1 ? "1 statement" : "\(statements) statements",
            words.isEmpty ? "no command" : words.sorted().joined(separator: "+"),
            files.isEmpty ? "no file" : files.count == 1 ? "one file" : "several files",
        ]
        if piped {
            parts.append("piped")
        }
        if withSift {
            parts.append("with sift")
        }
        return parts.joined(separator: " · ")
    }

    /// ``ShellSyntax/statements(of:)``, with a fragment `;`-split apart by a bare `((…))` — the C-style `for ((i=0;i<3;i++))`, never a `$(…)` or backtick substitution, which ``ShellSyntax`` already keeps whole — glued back into the one statement it is, and flagged `merged` so its own `;` is never mistaken for a pipeline boundary either.
    ///
    /// Counts adjacent `((`/`))` pairs rather than every parenthesis, so a subshell's own `(…)` — whose `;` really does start a new statement — is left untouched.
    private static func statementsGroupingArithmeticParens(of text: String) -> [(text: String, merged: Bool)] {
        var result: [(text: String, merged: Bool)] = []
        var pending = ""
        var piecesPending = 0
        var openDepth = 0
        for statementText in ShellSyntax.statements(of: text) {
            pending = pending.isEmpty ? statementText : pending + ";" + statementText
            piecesPending += 1
            openDepth += adjacentParenBalance(of: statementText)
            if openDepth <= 0 {
                result.append((pending, piecesPending > 1))
                pending = ""
                piecesPending = 0
                openDepth = 0
            }
        }
        if !pending.isEmpty {
            result.append((pending, piecesPending > 1))
        }
        return result
    }

    /// The count of adjacent `((` pairs in `text` minus the count of adjacent `))` pairs — positive while a bare arithmetic compound opened in it is still unclosed.
    private static func adjacentParenBalance(of text: String) -> Int {
        var balance = 0
        var previous: Character?
        for character in text {
            if character == "(", previous == "(" {
                balance += 1
            } else if character == ")", previous == ")" {
                balance -= 1
            }
            previous = character
        }
        return balance
    }

    /// Whether `token` is a shell variable assignment (`LC_ALL=C`) opening a statement ahead of its command.
    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && !(name.first?.isNumber ?? true)
    }

    /// The file `token` names, as written and unquoted, or `nil` where it never names one: a flag, a redirection, a directory, a pattern or glob field's value (see ``patternKeys``), a token holding a glob character.
    private static func namedFile(_ token: String) -> String? {
        guard !looksLikeFlag(token), !isRedirectionDup(token), redirectionFileForm(token) == nil else { return nil }
        var operand = token
        if let equals = token.firstIndex(of: "=") {
            let rawKey = String(token[..<equals])
            let key = rawKey.hasPrefix("--") ? String(rawKey.dropFirst(2)) : rawKey
            guard !patternKeys.contains(key) else { return nil }
            if keyedOperands.contains(rawKey) {
                operand = String(token[token.index(after: equals)...])
            }
        } else if !isQuoted(token), let colon = token.lastIndex(of: ":"), isPathLike(String(token[token.index(after: colon)...])) {
            operand = String(token[token.index(after: colon)...])
        }
        let bare = unquoted(operand)
        guard !bare.contains(where: { "*?[".contains($0) }) else { return nil }
        guard isPathLike(bare), let last = bare.split(separator: "/").last, isPathLike(String(last)) else { return nil }
        return bare
    }
}
