//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers what a comment in this repository may carry: the code's reasons, and not the history of how they were learned.
///
/// A comment ships with the code and is read by strangers, so it states what the code does and why as a property of the code. A date says when somebody found something out, and an issue number points into a tracker a reader of the published tree cannot open; both are history, and history is where the people, machines and sessions it happened to come to rest. The part of that rule a machine can check is checked here, and the judgement about undated anecdote stays with a reviewer:
///
/// - **Swift**, every `.swift` file in the tree — `Sources/`, `Tests/` and `Package.swift` alike: no comment line carries an ISO date, a `#` followed by digits, an issue or pull request named in words (`issue N`, `PR N`), or a tracker URL (`/issues/N`, `/pull/N`).
/// - **Shell**, every `*.sh` file and every hook under `githooks/`: no `#` comment carries an ISO date, a `#` followed by digits, an issue or pull request named in words, or a tracker URL. The `#`-and-digits check reads the comment after its leading run of `#` markers and the blanks that follow them, because in shell the marker itself is a `#` — so a reference later in the comment is found, while `#!/bin/sh`, a `## heading` and a heading that numbers itself straight after the marker are not, and a check that fired on those would get switched off.
///
/// **Comments only, never string literals.** A timestamp in a string literal is test data — a log line the suite parses, a window it narrows by — and holding it to this rule would mean rewriting inputs to satisfy prose. A Swift file's comments come from ``ExampleNameScanner``, which already tells comments from literals for the permit list; a shell comment is read from an unquoted `#` that starts a word. Fixture files that are neither are data and are not read at all.
struct CommentHistoryTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    /// A calendar date in ISO form, which is the spelling a dated note takes — standing alone, joined to a time by a `T`, or run into a word by an underscore.
    ///
    /// Bounded by digits rather than by a word boundary, because `T` and `_` are word characters and a `\b` there lets exactly those spellings through. The leading bound consumes the character before the year, since Swift's `Regex` has no look-behind; a check that only asks whether a line contains a date loses nothing by it.
    nonisolated(unsafe) static let isoDate = /(?:^|[^0-9])(?:19|20)\d{2}-[01]\d-[0-3]\d(?![0-9])/

    /// An issue or pull-request reference: `#` and digits, standing on their own.
    ///
    /// The digits have to end the token, so a hex colour such as `#1b1d1f` is not a reference, and `#if`, `#selector` and a raw string's opening `#` carry no digits at all. A colour can be written in digits alone too, so two shapes of one are set aside: a run of exactly six or eight digits (`#000000`, `#00000000`), a length no tracker reaches, and a run of three or four of one repeated digit (`#333`, `#0000`), a grey. Three or four mixed digits stay a reference — those lengths are ordinary issue numbers, and a colour written that way is rare enough to reword.
    nonisolated(unsafe) static let issueReference = /(?:^|\W)#(?!\d{6}\b|\d{8}\b|(\d)\1{2,3}\b)\d+\b/

    /// An issue or pull request named in words, or by the path a tracker gives it: `issue`, `issues`, `PR` or `pull request` and a number, or `issues/` or `pull/` and a number, with or without the slash before it.
    ///
    /// `issue` is a verb too, and what marks the verb is the word in front of it: after a pronoun or a modal — `we issue`, `it can issue` — the number is a count, which is why the word is captured and ``namesAnIssue(_:)`` sets those matches aside. Anything else in front, or nothing, is a reference wherever it stands in the sentence. `to` is deliberately not a marker: `refer to issue` and `related to issue`, each with its number, are among the commonest ways to name one.
    nonisolated(unsafe) static let namedReference =
        /(?i:(?:\b(we|they|you|it|will|can|may|might|should|shall|must|would|could)\s+)?\bissues?\s+#?\d+\b|\bpull\s+requests?\s+#?\d+\b|\b(?:issues|pull)\/\d+\b)|\bPRs?\s+#?\d+\b/

    /// Whether `text` names an issue or a pull request in words — a ``namedReference`` match that is not the verb.
    static func namesAnIssue(_ text: some StringProtocol) -> Bool {
        String(text).matches(of: namedReference).contains { $0.output.1 == nil }
    }

    /// Every Swift and shell file in the tree: what git tracks plus what it neither tracks nor ignores, less what `--deleted` names.
    ///
    /// The same set the permit list reads (``ExampleNamesTests/tree(in:)``), for the reason it gives: from `ls-files` alone the check would be blind rather than strict, and a dated comment in a new file would pass until the day somebody staged it. A scratch file is inside the check like any other; the way out is `.gitignore`.
    private static func checkedFiles() throws -> (swift: [String], shell: [String]) {
        let tree = try ExampleNamesTests.tree(in: repository)

        return (swift: tree.filter { $0.hasSuffix(".swift") }, shell: tree.filter(isShellScript))
    }

    /// A shell script by the tree's own conventions: a `.sh` file, or a hook under `githooks/`, which carries no extension.
    static func isShellScript(_ path: String) -> Bool {
        path.hasSuffix(".sh") || path.hasPrefix("githooks/")
    }

    /// The comment lines of one Swift file that carry a date or an issue reference, each with its line number and its comment text.
    ///
    /// Read from the comment half alone, which is the length of the source with everything else blanked and every newline kept, so a line of it is a line of the file. A file that is not UTF-8 is reported rather than skipped: a file this cannot read is a file it cannot clear.
    static func history(inSwift source: [UInt8]) -> [(line: Int, text: String)] {
        guard let comments = String(bytes: ExampleNameScanner.split(swift: source).comment, encoding: .utf8) else {
            return [(line: 0, text: "not UTF-8, so its comments could not be read")]
        }
        var found: [(line: Int, text: String)] = []
        for (offset, line) in comments.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard line.contains(isoDate) || line.contains(issueReference) || namesAnIssue(line) else { continue }
            found.append((line: offset + 1, text: line.trimmingCharacters(in: .whitespaces)))
        }

        return found
    }

    /// The `#` comments of one shell script that carry a date or an issue reference, each with its line number and its comment text.
    ///
    /// The `#`-and-digits check reads the comment with its leading markers and the blanks after them stripped, for the reason the type's documentation gives.
    static func history(inShell source: [UInt8]) -> [(line: Int, text: String)] {
        guard let text = String(bytes: source, encoding: .utf8) else {
            return [(line: 0, text: "not UTF-8, so its comments could not be read")]
        }
        var found: [(line: Int, text: String)] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let comment = shellComment(in: line) else { continue }
            let prose = comment.drop { $0 == "#" }.drop(while: \.isWhitespace)
            guard comment.contains(isoDate) || namesAnIssue(comment) || prose.contains(issueReference) else { continue }
            found.append((line: offset + 1, text: comment.trimmingCharacters(in: .whitespaces)))
        }

        return found
    }

    /// The comment on one line of shell, from its `#` to the end of the line, or `nil` when there is none.
    ///
    /// A `#` begins a comment where it begins a word and is not quoted — at the start of the line, or after whitespace or an operator — so `$#`, `${#name}` and a `#` inside quotes are not one. Quoting is followed within the line, which is all a comment can depend on; a heredoc body is read as ordinary lines, which errs towards reading more.
    static func shellComment(in line: Substring) -> Substring? {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            defer { previous = character }
            if escaped {
                escaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                }
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "'", "\"", "`":
                quote = character
            case "#" where startsAWord(after: previous):
                return line[index...]
            default:
                break
            }
        }

        return nil
    }

    /// Whether a character that follows `previous` begins a word: at the start of the line, or after whitespace or an operator.
    private static func startsAWord(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || ";|&()".contains(previous)
    }

    // MARK: - The tree

    /// No comment in the tree carries a date or an issue number.
    @Test
    func noCommentInTheTreeCarriesADateOrAnIssueNumber() throws {
        let files = try Self.checkedFiles()
        var found: [String] = []
        for path in files.swift {
            let source = try [UInt8](Data(contentsOf: Self.repository.appending(path: path)))
            for site in Self.history(inSwift: source) {
                found.append("  \(path):\(site.line)  \(site.text.prefix(140))")
            }
        }
        for path in files.shell {
            let source = try [UInt8](Data(contentsOf: Self.repository.appending(path: path)))
            for site in Self.history(inShell: source) {
                found.append("  \(path):\(site.line)  \(site.text.prefix(140))")
            }
        }

        // Reduced to a `Bool` before it is asserted on: a failure otherwise prints the captured
        // sub-expression, and the sub-expression is every finding in the tree.
        let undated = found.isEmpty

        #expect(undated, Comment(rawValue: """
        \(found.count) comment line\(found.count == 1 ? "" : "s") carr\(found.count == 1 ? "ies" : "y") a date or an issue reference:
        \(found.prefix(20).joined(separator: "\n"))
        \(found.count > 20 ? "  +\(found.count - 20) more\n" : "")
        State the rule, or the reason for it, as a property of the code. When it was learned and which ticket it was filed under are history, and the published tree carries neither. A date or a number that is test data belongs in a string literal, where this check does not read.
        """))
    }

    /// The check reads the manifest and the shell scripts, not only `Sources/` and `Tests/`.
    @Test
    func theManifestAndTheShellScriptsAreRead() throws {
        let files = try Self.checkedFiles()

        #expect(files.swift.contains("Package.swift"))
        #expect(files.shell.contains("githooks/pre-push"))
        #expect(files.shell.contains("Distribution/verify-tree.sh"))
    }

    // MARK: - What the check reads

    /// A date in a comment is found, on its own line or trailing code, and the same date in a string literal is not.
    @Test
    func aDatedCommentIsFoundAndTheSameDateInAStringIsNot() {
        let source = Array("""
        let stamp = "2026-08-18T10:00:00Z"
        /// Fixed on 2026-08-18.
        let window = 1 // see issue #13
        let label = "reported in #13"
        """.utf8)

        let found = CommentHistoryTests.history(inSwift: source)

        #expect(found.map(\.line) == [2, 3])
    }

    /// A date joined to a time, or run into a word, is still a date.
    @Test
    func aTimestampAndADateInsideAWordAreFound() {
        let source = Array("""
        // logged 2026-08-18T10:00:00Z
        // written to run_2026-08-18.log
        let value = 1
        """.utf8)

        #expect(CommentHistoryTests.history(inSwift: source).map(\.line) == [1, 2])
    }

    /// An issue or pull request named in words, or linked by its tracker path, is a reference like a `#` and its number.
    @Test
    func anIssueNamedInWordsOrByItsURLIsFound() {
        let source = Array("""
        // Tracked as issue 13.
        // Landed in PR 42, after pull request 41.
        // See https://example.com/org/repo/issues/13 and /pull/14.
        // Issues are listed in a tracker; a pull request needs review.
        // We issue 3 requests per batch.
        // Reopened as issue 14
        // see issue 13 for details
        // see issues 13 and 14
        // Fixed by issue 42 upstream
        // Mirrors issues/13 on the tracker.
        // Related to issue 7, which the retry answers.
        // Each worker can issue 2 at a time, and they issue 4 more after.
        let value = 1
        """.utf8)

        #expect(CommentHistoryTests.history(inSwift: source).map(\.line) == [1, 2, 3, 6, 7, 8, 9, 10, 11])
    }

    /// A `#` and digits is a reference at every length an issue number takes, and a grey written in digits alone is a colour.
    @Test
    func anIssueNumberIsFoundAndAGreyInDigitsIsNot() {
        let source = Array("""
        // Fixed in #13.
        // Follows #42.
        // Reverted by #123.
        // Grey text is #333 on #0000, the rule #111 and the shadow #000.
        let value = 1
        """.utf8)

        #expect(CommentHistoryTests.history(inSwift: source).map(\.line) == [1, 2, 3])
    }

    /// A block comment is read like a line comment, and a finding carries the line of the block it stands on.
    @Test
    func aDateInsideABlockCommentIsFoundOnItsOwnLine() {
        let source = Array("""
        /*
         An ordinary line.
         Changed in 2026-09 and again on 2026-09-10.
         */
        let value = 1
        """.utf8)

        #expect(CommentHistoryTests.history(inSwift: source).map(\.line) == [3])
    }

    /// A compiler directive, a hex colour and a year-and-month are not what this check is for.
    ///
    /// Each of these is ordinary in a comment about code: `#if` and `#selector` are Swift, a colour is a value — in digits alone as much as with letters — and a bare version or month names no day anything happened on.
    @Test
    func aDirectiveAColourAndAPartialDateAreNotFindings() {
        let source = Array("""
        // Guarded by #if DEBUG, reached through #selector.
        // The ink is #1b1d1f on #fbfbfc, the shadow #000000 at #00000000.
        // Swift 6.3.3, a window of 2026-09, and a range 1-2-3.
        let value = 1
        """.utf8)

        #expect(CommentHistoryTests.history(inSwift: source).isEmpty)
    }

    // MARK: - Shell

    /// A date in a shell comment is found, on its own line or trailing a command, and the same date in quotes or in code is not.
    @Test
    func aDateInAShellCommentIsFoundAndTheSameDateInCodeIsNot() {
        let source = Array("""
        #!/bin/sh
        # Fixed on 2026-08-18.
        STAMP="2026-08-18" # set on 2026-08-19
        echo "# 2026-08-20 is text" '# 2026-08-21 too'
        [ "$#" -gt 0 ] && echo "${#1}" 2026-08-22
            # see https://example.com/org/repo/issues/13
        """.utf8)

        let found = CommentHistoryTests.history(inShell: source)

        #expect(found.map(\.line) == [2, 3, 6])
        #expect(found.map(\.text).first == "# Fixed on 2026-08-18.")
    }

    /// A `#` and digits in a shell comment is a reference once the comment's own markers are set aside, and a shebang, a heading or a number opening the comment is not.
    @Test
    func anIssueNumberInAShellCommentIsFoundAndTheMarkerIsNot() {
        let source = Array("""
        #!/bin/sh
        ## Setup
        #1 Install the tools
        # fixed in #13
        run --quick # see #13
        echo "#13 is text"
        """.utf8)

        #expect(CommentHistoryTests.history(inShell: source).map(\.line) == [4, 5])
    }

    /// A `#` begins a shell comment only where it begins an unquoted word.
    @Test
    func aShellCommentStartsAtAnUnquotedHashThatBeginsAWord() {
        #expect(CommentHistoryTests.shellComment(in: "echo $# ${#name} a#b") == nil)
        #expect(CommentHistoryTests.shellComment(in: ##"echo "a # b" 'c # d' \# e"##) == nil)
        #expect(CommentHistoryTests.shellComment(in: "run;# note") == "# note")
        #expect(CommentHistoryTests.shellComment(in: "  # indented") == "# indented")
    }

    /// The tree's shell scripts are the `.sh` files and the extensionless hooks.
    @Test
    func aShellScriptIsASHFileOrAHook() {
        #expect(CommentHistoryTests.isShellScript("setup.sh"))
        #expect(CommentHistoryTests.isShellScript("githooks/pre-commit"))
        #expect(!CommentHistoryTests.isShellScript("Distribution/homebrew/sift.rb"))
        #expect(!CommentHistoryTests.isShellScript("Distribution/private-terms.txt"))
    }
}
