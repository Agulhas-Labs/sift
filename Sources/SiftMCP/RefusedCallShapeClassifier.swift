//
// Copyright © Agulhas Labs
//

import Foundation

/// Classifies a refused call's shape — a shell window, a whole-file read, a conflict-marker search, an alternation — the same reading the advice hook and the scan share (``TranscriptScan``'s thin `refusedCallShape` wrappers).
struct RefusedCallShapeClassifier {
    /// The shape of a refused whole-file `Read`: never ranged, since a ranged read is never refused.
    static func shape(read path: String, cwd: String? = nil) -> RefusedCallShape {
        let text = "Read \(path)"
        return RefusedCallShape(tool: "Read", text: text, kind: classify(text: text, cwd: cwd, isWholeFileRead: true))
    }

    /// The shape of a refused `Grep`/`Glob`, built from the same fields the hook itself read to advise on it.
    static func shape(searchTool tool: String, input: [String: Any], cwd: String? = nil) -> RefusedCallShape {
        let pattern = input["pattern"] as? String
        var parts = [tool]
        if let pattern {
            parts.append("pattern=\(pattern)")
        }
        if let path = input["path"] as? String, !path.isEmpty {
            parts.append("path=\(path)")
        }
        if let glob = input["glob"] as? String, !glob.isEmpty {
            parts.append("glob=\(glob)")
        }
        if let type = input["type"] as? String, !type.isEmpty {
            parts.append("type=\(type)")
        }
        let text = parts.joined(separator: " ")
        // The Grep/Glob tools are ripgrep underneath, so their patterns are always read in the extended dialect.
        return RefusedCallShape(
            tool: tool,
            text: text,
            kind: classify(text: text, cwd: cwd, pattern: pattern, regexIsExtended: true),
            key: canonicalKey(input, fallback: text)
        )
    }

    /// The shape of a refused Bash lookup — a shell window or a generic search, both read through `ShellQuery` the same way the rest of this file reads a command's other properties.
    static func shape(bash command: String, cwd: String? = nil) -> RefusedCallShape {
        let text = "Bash: \(command)"
        let query = ShellQuery(command)
        let invocation = query.invocation
        let basename = invocation.first(where: { !$0.isEmpty }).map { URL(fileURLWithPath: $0).lastPathComponent }
        let usesFixedStrings = query.usesFixedStrings
        let usesExtendedRegexFlag = hasShortFlag("E", longName: "--extended-regexp", in: invocation) || basename == "egrep"
        // ripgrep (the `rg` command) has no basic-regex mode at all — its patterns are extended by default, flag or no flag.
        let isRipgrep = if case .ripgrep = query.tool {
            true
        } else {
            false
        }
        let regexIsExtended = usesExtendedRegexFlag || isRipgrep
        let namesAnotherRevision = query.searchesOtherRevision
            || command.contains("git show")
            || (command.contains("git log") && (command.contains(" -p") || command.contains("--patch")))
        let isWholeFileRead = basename == "cat" && query.swiftFiles.count == 1
        let kind = classify(
            text: text,
            cwd: cwd,
            pattern: query.pattern,
            usesFixedStrings: usesFixedStrings,
            regexIsExtended: regexIsExtended,
            namesAnotherRevision: namesAnotherRevision,
            isShellWindow: query.windowsLines,
            isWholeFileRead: isWholeFileRead
        )
        return RefusedCallShape(tool: "Bash", text: text, kind: kind)
    }

    /// `input`, canonicalised so an identical call always produces the same key regardless of dictionary ordering — `JSONSerialization` with `.sortedKeys` — or `fallback` where `input` cannot be serialized, which a well-formed tool call's input never is.
    private static func canonicalKey(_ input: [String: Any], fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let key = String(bytes: data, encoding: .utf8)
        else {
            return fallback
        }
        return key
    }

    /// A short-flag cluster (`-rnE`) carrying `letter`, or a matching long flag — `grep -E`/`--extended-regexp`, `grep -F`/`--fixed-strings` — spelled either way.
    private static func hasShortFlag(_ letter: Character, longName: String, in invocation: [String]) -> Bool {
        invocation.contains { argument in
            if argument == longName {
                return true
            }
            guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else { return false }
            return argument.dropFirst().allSatisfy(\.isLetter) && argument.contains(letter)
        }
    }

    /// Whether the call's display text names a path outside the indexed sources, by the one definition the hook and the scan read (``SwiftTree/isOutsideIndexedSources(_:)``) — asked of each word, with a `key=` label or a flag's `=` and any quotes taken off it, since the display text is all a refused call's shape is built from, whichever tool named the path.
    ///
    /// Judged against `cwd`, the call's own working directory, so a repository merely sitting inside a directory named `checkouts` (or `Pods`, or `Carthage`) is not read as outside just because its absolute path carries that name.
    private static func namesAPathOutsideIndexedSources(_ text: String, cwd: String?) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains { word in
            let value = word.split(separator: "=", maxSplits: 1).last ?? word
            return SwiftTree.isOutsideIndexedSources(
                value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
                relativeTo: cwd
            )
        }
    }

    /// First match wins, in the order ``RefusalShape`` declares its cases.
    private static func classify(
        text: String,
        cwd: String? = nil,
        pattern: String? = nil,
        usesFixedStrings: Bool = false,
        regexIsExtended: Bool = false,
        namesAnotherRevision: Bool = false,
        isShellWindow: Bool = false,
        isWholeFileRead: Bool = false
    ) -> RefusalShape {
        if let pattern, pattern.contains("<<<<<<<") || pattern.contains(">>>>>>>") {
            return .conflictMarkers
        }
        if namesAnotherRevision {
            return .anotherRevision
        }
        if namesAPathOutsideIndexedSources(text, cwd: cwd) {
            return .outsideIndexedSources
        }
        if usesFixedStrings {
            return .fixedString
        }
        if let pattern, pattern.contains(" ") {
            return .phrase
        }
        if let pattern, containsAlternation(pattern, extended: regexIsExtended) {
            return .alternation
        }
        if isShellWindow {
            return .shellWindow
        }
        if isWholeFileRead {
            return .wholeFileRead
        }
        return .other
    }

    /// Whether `pattern` alternates between literal choices, read in the dialect `extended` names — an unescaped `|` in extended regex (ripgrep's own default, `grep -E`/`egrep`) or an escaped `\|` in POSIX basic regex (plain `grep`), since the two conventions read the same character oppositely.
    private static func containsAlternation(_ pattern: String, extended: Bool) -> Bool {
        extended
            ? pattern.replacingOccurrences(of: #"\|"#, with: "").contains("|")
            : pattern.contains(#"\|"#)
    }
}
