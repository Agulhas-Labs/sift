//
// Copyright © Agulhas Labs
//

import Foundation

/// The closed flag vocabulary a call's shape keeps verbatim: every other flag word is redacted, however much it reads like a flag.
struct ShapeFlagVocabulary {
    /// Commands that can take their pattern or script through a flag instead, every such flag's own operand reading `<pattern>` and leaving no operand after it to be one.
    static let patternFlagCommands: Set<String> = ["grep", "egrep", "rg", "sed"]

    /// The flags that hand ``patternFlagCommands`` a pattern, a script, or a file of one.
    static let patternFlags: Set<String> = ["-e", "--regexp", "-f", "--expression"]

    /// The flags, per command, whose separate next word is a plain value — a context count, a match limit, an `awk` variable, a field separator, a program file, a backup suffix, a working directory or a `.git` directory, a glob or a type filter that narrows which files `rg` searches without naming its pattern — never the pattern or script.
    static let valueFlagsByCommand: [String: Set<String>] = [
        "grep": ["-A", "-B", "-C", "-m", "--max-count", "--context"],
        "egrep": ["-A", "-B", "-C", "-m"],
        "rg": ["-A", "-B", "-C", "-m", "-g", "-t", "--type"],
        "awk": ["-v", "-F", "-f"],
        "sed": ["-i"],
        "git": ["-C", "--git-dir"],
    ]

    /// The letters, per command, that are its own value-less short flags, so a single-dash cluster spelled from nothing but them (`-rnw`, `-la`) is kept whole.
    ///
    /// Each set is kept to the letters people actually cluster, not every flag the command has: a word spelled from nothing but a command's letters is indistinguishable from a real cluster, so a longer set lets more of a glued word through. A command listed here with an empty set clusters no letters at all (`find`'s primaries and `xcodebuild`'s options are words, listed in ``singleDashWordsByCommand``).
    static let valuelessLettersByCommand: [String: Set<Character>] = [
        "grep": ["c", "E", "F", "H", "h", "I", "i", "l", "L", "n", "o", "q", "r", "R", "s", "v", "w", "x"],
        "egrep": ["c", "H", "h", "I", "i", "l", "L", "n", "o", "q", "r", "R", "s", "v", "w", "x"],
        "rg": ["c", "F", "H", "i", "l", "L", "n", "N", "o", "P", "S", "s", "U", "u", "v", "w", "x"],
        "sed": ["E", "n", "r", "s", "u"],
        "awk": [],
        "git": ["a", "d", "D", "f", "p", "q", "s", "v", "x"],
        "gh": ["w"],
        "find": [],
        "ls": ["A", "a", "F", "G", "h", "l", "R", "r", "S", "t"],
        "cut": ["n", "s", "w"],
        "xcodebuild": [],
        "swift": ["q", "v"],
    ]

    /// The single-dash words, per command, that are its own options spelled as one word rather than a cluster of letters, each kept whole.
    static let singleDashWordsByCommand: [String: Set<String>] = [
        "find": [
            "name", "iname", "path", "ipath", "type", "maxdepth", "mindepth", "print", "exec", "execdir",
            "delete", "newer", "mtime", "mmin", "size", "prune", "not", "and", "or", "empty", "regex",
            "iregex", "depth", "perm", "user", "follow", "ls",
        ],
        "xcodebuild": [
            "scheme", "project", "workspace", "destination", "configuration", "sdk", "target", "quiet",
            "list", "arch", "alltargets", "version", "json", "derivedDataPath", "showBuildSettings",
            "allowProvisioningUpdates", "enableCodeCoverage", "archivePath", "exportArchive", "exportPath",
            "exportOptionsPlist", "resolvePackageDependencies", "skipPackagePluginValidation",
            "skipMacroValidation", "xcconfig", "toolchain", "usage", "help", "license",
        ],
    ]

    /// The double-dash flags a shape keeps verbatim beside the value and pattern flags already listed per command; any other long flag reads `--<text>`.
    static let knownLongFlags: Set<String> = [
        "--help", "--version", "--verbose", "--quiet", "--silent", "--json", "--color", "--colour",
        "--include", "--exclude", "--exclude-dir", "--line-number", "--recursive", "--ignore-case",
        "--word-regexp", "--files-with-matches", "--files-without-match", "--count", "--invert-match",
        "--fixed-strings", "--extended-regexp", "--only-matching", "--no-filename", "--with-filename",
        "--after-context", "--before-context", "--null", "--no-messages", "--binary-files",
        "--type", "--glob", "--hidden", "--no-ignore", "--files", "--vimgrep", "--smart-case",
        "--multiline", "--no-heading", "--heading", "--column", "--max-depth", "--follow", "--sort",
        "--oneline", "--stat", "--name-only", "--name-status", "--graph", "--all", "--decorate",
        "--no-pager", "--porcelain", "--short", "--cached", "--staged", "--format", "--pretty",
        "--since", "--until", "--author", "--grep", "--patch", "--reverse", "--no-merges",
        "--first-parent", "--numstat", "--shortstat", "--no-color", "--force", "--force-with-lease",
        "--amend", "--no-edit", "--hard", "--soft", "--rebase", "--ff-only", "--no-ff", "--squash",
        "--abort", "--continue", "--dry-run", "--list", "--tags", "--prune", "--show-toplevel",
        "--is-ancestor", "--abbrev-ref", "--verify", "--contains", "--merged",
        "--repo", "--jq", "--limit", "--state", "--label", "--title", "--body", "--body-file",
        "--web", "--search", "--assignee", "--comments", "--base", "--head", "--draft", "--fill",
        "--paginate", "--method", "--field", "--raw-field", "--input",
        "--filter", "--skip", "--package-path", "--configuration", "--product", "--target",
        "--parallel", "--scratch-path", "--build-path", "--show-bin-path", "--skip-build",
        "--list-tests", "--disable-sandbox",
        "--in-place", "--regexp-extended", "--lines", "--bytes", "--words", "--chars",
        "--numeric-sort", "--unique", "--delimiter", "--fields", "--characters",
        "--replay", "--shapes", "--proved", "--shards", "--unredact", "--root", "--full",
    ]

    /// Whether `letter`, as a short flag of `command`'s own, takes a value — `true` for a pattern, `false` for a plain value, `nil` for neither.
    static func flagLetterTakesValue(_ letter: Character, for command: String) -> Bool? {
        let asFlag = "-\(letter)"
        if patternFlagCommands.contains(command), patternFlags.contains(asFlag) {
            return true
        }
        if valueFlagsByCommand[command]?.contains(asFlag) == true {
            return false
        }
        return nil
    }

    /// Whether `token`, a double-dash flag, is on one of the closed lists a shape keeps verbatim: any command's value flags, the pattern flags, or ``knownLongFlags``.
    static func isListedLongFlag(_ token: String) -> Bool {
        knownLongFlags.contains(token) || patternFlags.contains(token) || valueFlagsByCommand.values.contains { $0.contains(token) }
    }

    /// How much of `rest` — a single-dash flag's body, the characters after its dash — survives as `command`'s own flags, and what the remainder is.
    ///
    /// `kept` counts the leading characters kept as written; when it falls short of the whole body, the second element says the remainder is a value glued onto the flag letter just before it (`true` for a pattern, `false` for a plain value), or, `nil`, a word no flag of `command` accounts for.
    static func clusterReading(_ rest: Substring, for command: String) -> (kept: Int, gluedValueIsPattern: Bool?) {
        if singleDashWordsByCommand[command]?.contains(String(rest)) == true {
            return (rest.count, nil)
        }
        let leadingLetter = rest.first.map { $0.isASCII && $0.isLetter } == true ? 1 : 0
        guard let valueless = valuelessLettersByCommand[command] else {
            let whole = rest.count == 1 || (rest.count <= 3 && rest.allSatisfy { $0.isASCII && $0.isLowercase })
            return (whole ? rest.count : leadingLetter, nil)
        }
        var kept = 0
        for letter in rest {
            if let isPattern = flagLetterTakesValue(letter, for: command) {
                return (kept + 1, isPattern)
            }
            guard valueless.contains(letter) else { break }
            kept += 1
        }
        return (kept == 0 ? leadingLetter : kept, nil)
    }
}
