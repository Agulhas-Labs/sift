//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A shell comment runs nothing: it is never a lookup, and never what makes one command a different command from another.
@Suite(.temporaryDirectories)
struct ShellCommentTests {
    /// The refused command and its retry, as a caller writes them: the retry drops the comment and changes nothing that runs.
    private static var refused: String {
        """
        # Keep only the body of the literal
        awk '/let summary = /{flag=1; next} flag' Sources/App/Alpha.swift
        """
    }

    private static var retry: String {
        """
        awk '/let summary = /{flag=1; next} flag' Sources/App/Alpha.swift
        """
    }

    /// The promise every refusal makes is that the identical re-run passes, and a retry that differs only in a comment is identical in everything it runs.
    ///
    /// Keyed on its whole text, the retry was a new command to the ledger and was refused a second time.
    @Test
    func aRetryThatDropsACommentIsTheSameCommand() throws {
        let directory = try TemporaryDirectory.make("ledger").appendingPathComponent("ledger")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AdviceLedger(directory: directory)
        let noted = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        let first = try #require(PreToolUseCommand.lookup(command: Self.refused, payload: [:], noting: noted, couldAnswer: { _, _ in true }))
        let second = try #require(PreToolUseCommand.lookup(command: Self.retry, payload: [:], noting: noted, couldAnswer: { _, _ in true }))

        #expect(first.key == second.key)
        #expect(ledger.refuse(session: "s1", command: first.key) == .advise)
        #expect(ledger.refuse(session: "s1", command: second.key) == .allow)
    }

    /// The scan reads the retry the way the hook does: a re-run the hook let through, scored out of the share as the escape hatch it was offered as.
    @Test
    func theScanExcusesTheRetryTheHookLetThrough() {
        let lines = [
            TranscriptFixture.toolUse("Bash", id: "c1", input: ["command": Self.refused]),
            TranscriptFixture.toolResult(id: "c1", isError: true, text: TranscriptFixture.refusal(call: "digest Alpha"), bareText: true),
            TranscriptFixture.toolUse("Bash", id: "c2", input: ["command": Self.retry]),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
    }

    /// A comment that spells a lookup is not one, on either surface.
    @Test
    func aCommentSpellingAGrepIsNotALookup() {
        let script = "# grep -n 'func go' Sources/App/Alpha.swift was the old check\nswift --version"

        #expect(!ShellInspection.isSwiftLookup(script))
        #expect(ShellAdvice.suggestion(for: script, holdsSource: nil) == nil)
    }

    /// A `#` that opens no word, or sits inside quotes or a substitution, is not a comment, and the command keeps every character of it.
    @Test(arguments: [
        "grep -rn '#if DEBUG' Sources --include=*.swift",
        ##"grep -n "#Preview" Sources/App/Alpha.swift"##,
        "echo $# ${#names} a#b",
        "grep -n \\#if Sources/App/Alpha.swift",
        #"echo "$(printf '%s' "a #b")""#,
    ])
    func aHashThatOpensNoWordIsNotAComment(command: String) {
        #expect(ShellSyntax.statements(of: command) == [command])
    }

    /// A comment on the line after a heredoc opener is part of the body, and a comment spelling `<<` opens no heredoc that would swallow the lines after it.
    @Test
    func aCommentSpellingAHeredocOpensNone() {
        let script = "# read it with cat <<EOF\ngrep -n 'func go' Sources/App/Alpha.swift"

        #expect(ShellInspection.isSwiftLookup(script))
    }

    /// A `Grep` key holds a pattern, where `#` is the text being searched for: two searches for different directives stay two searches.
    @Test
    func aSearchToolsKeyKeepsItsHash() {
        #expect(AdviceLedger.key(for: "Grep #if DEBUG Sources") != AdviceLedger.key(for: "Grep #Preview Sources"))
    }
}
