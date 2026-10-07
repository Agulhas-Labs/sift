//
// Copyright © Agulhas Labs
//

import Foundation

/// The per-token and per-flag readers behind `TranscriptAudit.CallRedaction.shape(of:)`: how one word of a call reads once its position in the statement is already known.
struct ShapeTokenReader {
    /// `key=` prefixes a tool call's own text spells a number with.
    private static let numberKeys: Set<String> = ["offset", "limit"]

    /// Whether a shell operator ends the statement it closes, so the next word opens a new command.
    static func endsStatement(_ token: String) -> Bool {
        TranscriptAudit.CallRedaction.lineContinuationOperators.contains(token) || token == ";"
    }

    /// The body of `token` if it is a single-dash flag of two or more characters, the only kind that can cluster letters or glue a value on, and `nil` for anything else.
    private static func shortClusterBody(of token: String) -> Substring? {
        guard TranscriptAudit.CallRedaction.looksLikeFlag(token), !token.hasPrefix("--") else { return nil }
        let rest = token.dropFirst()
        return rest.count > 1 ? rest : nil
    }

    /// Whether `token` is one of `command`'s own flags that takes the next word as its value — `true` when that word is a pattern (`grep -e`, `grep -ie`), `false` when it is a plain value (`grep -A`, `git -C`), `nil` when it takes no word after it.
    static func flagTakesValue(_ token: String, for command: String) -> Bool? {
        if ShapeFlagVocabulary.patternFlagCommands.contains(command), ShapeFlagVocabulary.patternFlags.contains(token) {
            return true
        }
        if ShapeFlagVocabulary.valueFlagsByCommand[command]?.contains(token) == true {
            return false
        }
        return clusteredFlagTakesValue(token, for: command)
    }

    /// Whether `token` is a flag cluster that ends in one of `command`'s own flags with nothing glued after it — `true` when that letter takes a pattern (`-ie` behaves as `-i -e`), `false` when it takes a plain value (`-im` behaves as `-i -m`), `nil` when the cluster names neither or glues a value on, so it takes no word after it.
    private static func clusteredFlagTakesValue(_ token: String, for command: String) -> Bool? {
        guard let rest = shortClusterBody(of: token), let last = rest.last else { return nil }
        guard ShapeFlagVocabulary.clusterReading(rest, for: command).kept == rest.count else { return nil }
        return ShapeFlagVocabulary.flagLetterTakesValue(last, for: command)
    }

    /// Whether `token` opens with one of `command`'s own single-dash flags though something ``TranscriptAudit/CallRedaction/looksLikeFlag(_:)`` never allows in a cluster is glued after it — a `.` (`sed -i.bak`) or a `:` (`awk -F:`) — which would otherwise be misread as a bare operand.
    static func opensWithKnownFlagLetter(_ token: String, for command: String) -> Bool {
        guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
        return ShapeFlagVocabulary.clusterReading(token.dropFirst(), for: command).kept > 0
    }

    /// Whether a spaced `-i` after `sed` — `tokens[index]` — takes the next word as a macOS backup suffix: true unless that word looks like a flag or is a quoted, non-empty script, either of which means the GNU form, where `-i` takes no word and the next word is the script.
    static func sedInPlaceTakesSpacedValue(_ tokens: [String], at index: Int) -> Bool {
        guard index + 1 < tokens.count else { return false }
        let next = tokens[index + 1]
        if TranscriptAudit.CallRedaction.looksLikeFlag(next) {
            return false
        }
        if TranscriptAudit.CallRedaction.isQuoted(next), !TranscriptAudit.CallRedaction.unquoted(next).isEmpty {
            return false
        }
        return true
    }

    /// Whether `token` glues a pattern straight onto one of `command`'s own pattern flags (`-edepot`, `-rnedepot`), handing the command its pattern the way a separate `-e` does.
    private static func gluesPattern(_ token: String, for command: String) -> Bool {
        guard let rest = shortClusterBody(of: token) else { return false }
        let reading = ShapeFlagVocabulary.clusterReading(rest, for: command)
        return reading.kept < rest.count && reading.gluedValueIsPattern == true
    }

    /// Whether a pattern flag later in the same statement hands the command its pattern or script, so none of its bare operands is one.
    static func patternGivenByFlag(to command: String, in tokens: [String], after index: Int) -> Bool {
        guard ShapeFlagVocabulary.patternFlagCommands.contains(command) else { return false }
        for token in tokens[(index + 1)...] {
            if token == "--" || (TranscriptAudit.CallRedaction.shellOperators.contains(token) && endsStatement(token)) {
                return false
            }
            if ShapeFlagVocabulary.patternFlags.contains(token) || token.hasPrefix("--regexp=") || clusteredFlagTakesValue(token, for: command) == true || gluesPattern(token, for: command) {
                return true
            }
        }
        return false
    }

    /// `token` up to its first `=` — the flag word a glued `--flag=value` spells — or the whole token when it has none.
    static func flagWord(of token: String) -> String {
        token.firstIndex(of: "=").map { String(token[..<$0]) } ?? token
    }

    /// Whether a word is a whole fd-prefixed or file redirection, which never stands in an operand's place.
    static func isRedirection(_ token: String) -> Bool {
        TranscriptAudit.CallRedaction.isRedirectionDup(token) || TranscriptAudit.CallRedaction.redirectionFileForm(token) != nil
    }

    /// One token of a call's text as its shape spells it.
    ///
    /// The caller marks a `grep`-style pattern or a `sed`/`awk` address or script — an operand already known not to be a flag — which reads `<pattern>` unless it is a `sed` line address, which keeps reading `<range>`. `command` is the statement's own command word, used to spell a glued flag value (see ``shapedFlag(_:for:)``) by its kind. `shapedToken(_:asPattern:command:closesSubcommandTracking:)`'s last flag marks the one call in ``TranscriptAudit/CallRedaction/shape(of:)`` for the token that is itself closing a still-open subcommand position for a tool in ``TranscriptAudit/CallRedaction/subcommandsByTool`` — it reads by base rules like any other command's token (`git grep …` keeps `grep`); a later word arriving once that position is already closed (`git --unknown-flag X log` never keeps `log`) does not, and neither does a word for a command outside that table at all (`xargs grep …`, `if grep …` always keep `grep`, `echo`).
    static func shapedToken(_ token: String, asPattern: Bool = false, command: String = "", closesSubcommandTracking: Bool = false) -> String {
        if asPattern {
            let bare = TranscriptAudit.CallRedaction.unquoted(token)
            return isLineRange(bare) ? "<range>" : "<pattern>"
        }
        if TranscriptAudit.CallRedaction.shellOperators.contains(token) || TranscriptAudit.CallRedaction.isRedirectionDup(token) {
            return token
        }
        if let split = TranscriptAudit.CallRedaction.redirectionFileForm(token) {
            return split.operatorPart + shapedToken(split.operand)
        }
        if let equals = token.firstIndex(of: "=") {
            let key = String(token[..<equals])
            if TranscriptAudit.CallRedaction.keyedOperands.contains(key) || numberKeys.contains(key) || TranscriptAudit.CallRedaction.looksLikeFlag(key) {
                let value = String(token[token.index(after: equals)...])
                let shapedKey = TranscriptAudit.CallRedaction.looksLikeFlag(key) ? shapedFlag(key, for: command) : key
                return "\(shapedKey)=" + (key == "pattern" || key == "--regexp" ? shapedToken(value, asPattern: true) : placeholder(for: value))
            }
        }
        if TranscriptAudit.CallRedaction.looksLikeFlag(token) || opensWithKnownFlagLetter(token, for: command) {
            return shapedFlag(token, for: command)
        }
        if !TranscriptAudit.CallRedaction.isQuoted(token), let colon = token.lastIndex(of: ":") {
            let revision = String(token[..<colon])
            let path = String(token[token.index(after: colon)...])
            if TranscriptAudit.CallRedaction.isPathLike(path) {
                return (TranscriptAudit.CallRedaction.isHEADRelative(revision) ? revision : "<rev>") + ":" + placeholder(for: path)
            }
        }
        if closesSubcommandTracking || TranscriptAudit.CallRedaction.subcommandsByTool[command] == nil, TranscriptAudit.CallRedaction.safeWords.contains(token) {
            return token
        }
        if token == "---" {
            return token
        }
        return placeholder(for: token)
    }

    /// The kind of thing `operand` names: a number, a line range, a file, a path, or text.
    static func placeholder(for operand: String) -> String {
        let bare = TranscriptAudit.CallRedaction.unquoted(operand)
        if TranscriptAudit.CallRedaction.isBareInteger(bare) {
            return "<n>"
        }
        if isLineRange(bare) {
            return "<range>"
        }
        guard TranscriptAudit.CallRedaction.isPathLike(bare) else { return "<text>" }
        let last = bare.split(separator: "/").last.map(String.init) ?? ""
        return TranscriptAudit.CallRedaction.isPathLike(last) ? "<file>" : "<path>"
    }

    /// Whether `word` is a `sed` line address — `95,135p`, `5p`, `95,$p`, `1,+40p` — rather than a pattern or a name.
    private static func isLineRange(_ word: String) -> Bool {
        let command = word.last.map { "pd".contains($0) } ?? false
        let address = command ? word.dropLast() : Substring(word)
        let parts = address.split(separator: ",", omittingEmptySubsequences: false)
        guard command || parts.count == 2, (1 ... 2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            let digits = part.hasPrefix("+") ? part.dropFirst() : part
            return part == "$" || (!digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    /// `token` — already known to look like a flag — shaped so that nothing glued onto it survives.
    ///
    /// A double-dash flag is kept only when it is on a closed list (a command's value flags, the pattern flags, ``ShapeFlagVocabulary/knownLongFlags``), and reads `--<text>` otherwise. A single-dash flag survives whole only when it is one of `command`'s own single-dash words (`find -name`, `xcodebuild -scheme`) or every letter of it is one of `command`'s own value-less letters, a value or pattern flag allowed as its last letter (`-rnw`, `-ie`); for a command with no letter set, a single character or a lowercase cluster of at most three letters (`-la`, `-xzf`) survives whole. Otherwise the leading run of value-less letters survives, or the first letter alone when that run is empty: a value or pattern flag letter met in the run keeps that letter too and reads everything glued after it by that flag's kind (`-e<pattern>`, `-t<text>`, `-A<n>`), and any other letter ends the run and everything from it on reads `<text>` (`grep -xyoung` reads `-x<text>`, `git commit -mwip` reads `-m<text>`), or spells its digit runs `<n>` when no letter is left in it (`-c1-240`, `-40`). The split runs before digits are looked at, so a digit in a glued word never keeps the word.
    private static func shapedFlag(_ token: String, for command: String = "") -> String {
        let (dashes, rest) = TranscriptAudit.CallRedaction.flagBody(token)
        guard dashes == "-" else {
            return ShapeFlagVocabulary.isListedLongFlag(token) ? token : dashes + "<text>"
        }
        let reading = ShapeFlagVocabulary.clusterReading(rest, for: command)
        guard reading.kept < rest.count else { return token }
        let tail = String(rest.dropFirst(reading.kept))
        let shapedTail = switch reading.gluedValueIsPattern {
        case true?: shapedToken(tail, asPattern: true)
        case false?: placeholder(for: tail)
        case nil: tail.contains(where: \.isLetter) ? "<text>" : withNumbersShaped(tail)
        }
        return dashes + String(rest.prefix(reading.kept)) + shapedTail
    }

    /// `flag` with each run of digits in it spelled `<n>`, so `-A3` and `-A5` read the same.
    private static func withNumbersShaped(_ flag: String) -> String {
        var result = ""
        var inDigits = false
        for character in flag {
            if character.isASCII, character.isNumber {
                if !inDigits {
                    result += "<n>"
                }
                inDigits = true
            } else {
                result.append(character)
                inDigits = false
            }
        }
        return result
    }
}
