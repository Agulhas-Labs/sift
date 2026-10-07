//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An answer the hook gave in place of a Bash line is placed where the line's lookups ran — behind every literal `cd` in front of them, as the ledger places a shell digest — and nowhere behind a move that cannot be followed.
@Suite(.temporaryDirectories) struct CdAnswerPlacementTests {
    /// The hook's answer to a `cat` of `Alpha.swift`, as its refusal writes it into the transcript.
    private static var answerText: String {
        let answer = "tree: repo (worktree agent-gone)  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        return "PreToolUse:Bash hook error: " + InPlaceAnswer.reason(calls: ["digest Sources/App/Alpha.swift"], answer: answer, source: nil, standsIn: "", wholeCommand: false).text
    }

    /// How the window `window`, run from `cwd` after the hook answered `line` from `cwd` in place, is scored.
    private static func window(_ window: String, after line: String, cwd: String) -> SwiftLookup? {
        TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": line], cwd: cwd),
                TranscriptFixture.toolResult(id: "b1", isError: true, text: answerText),
                TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": window], cwd: cwd),
            ],
            belowFloor: { _ in false }
        ).last
    }

    /// The line's directory as ``PendingRead/answeredFrom`` reads it for a Bash line `command` run from `directory`.
    private static func answeredFrom(_ command: String, from directory: String?) -> String? {
        PendingRead(
            lookup: .revisited(file: "Alpha.swift"),
            path: "Alpha.swift",
            openedPath: false,
            counted: true,
            directory: directory,
            shape: RefusedCallShape(tool: "Bash", text: "Bash: " + command, kind: .other)
        ).answeredFrom
    }

    /// The defect: a line moving more than once was anchored at the directory it was run from, so the window after it, in the checkout it had moved into, was cold.
    ///
    /// Each move is followed, as the ledger follows it, and only the list in front of a `||` is read, since the fallback never ran.
    @Test(arguments: [
        "cd {HERE} && cd {GONE} && cat Sources/App/Alpha.swift",
        "cd {HERE}; cd {GONE}; cat Sources/App/Alpha.swift",
        "cd {HERE} && cd .claude/worktrees/agent-gone && cat Sources/App/Alpha.swift",
        "cd {GONE} && cat Sources/App/Alpha.swift || cd ..",
        "cd Sources && cd ../.claude/worktrees/agent-gone && cat Sources/App/Alpha.swift",
    ])
    func anAnswerBehindEveryCdLocatesItsFileWhereTheLineMoved(line: String) throws {
        let here = try MCPTestRepo.make()
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        let command = line.replacing("{HERE}", with: here.path).replacing("{GONE}", with: gone)

        let lookup = Self.window("cd \(gone) && sed -n 3,9p Sources/App/Alpha.swift", after: command, cwd: here.path)

        #expect(lookup == .guided(file: "Sources/App/Alpha.swift"))
    }

    /// Into another repository that is still on disk, from a third: the answer locates that repository's file, which a later window names in full.
    @Test
    func anAnswerBehindEveryCdIntoAnotherRepositoryLocatesItsFileThere() throws {
        let parent = try TemporaryDirectory.make("trio")
        let here = try MCPTestRepo.make(at: parent.appendingPathComponent("here"))
        let other = try MCPTestRepo.make(at: parent.appendingPathComponent("other"))
        let third = try MCPTestRepo.make(at: parent.appendingPathComponent("third"))
        let file = other.appendingPathComponent("Sources/App/Alpha.swift").path

        let lookup = Self.window(
            "sed -n 3,9p \(file)",
            after: "cd \(here.path) && cd ../other && cat Sources/App/Alpha.swift",
            cwd: third.path
        )

        #expect(lookup == .guided(file: file))
    }

    /// A move the scan cannot follow leaves the checkout the answer was read in unknown: anchoring it at the line's own directory located that repository's own `Alpha.swift`, which the answer never showed.
    @Test(arguments: [
        "pushd {GONE} && cat Sources/App/Alpha.swift",
        "cd - && cat Sources/App/Alpha.swift",
        "cd {GONE} | cat Sources/App/Alpha.swift",
        "echo $(cd {GONE}) && cd {GONE} && cat Sources/App/Alpha.swift",
    ])
    func anAnswerBehindAMoveThatCannotBeFollowedLocatesNothing(line: String) throws {
        let here = try MCPTestRepo.make()
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        let command = line.replacing("{GONE}", with: gone)

        let lookup = Self.window("sed -n 3,9p Sources/App/Alpha.swift", after: command, cwd: here.path)

        #expect(lookup != .guided(file: "Sources/App/Alpha.swift"))
    }

    /// A line that moves nowhere is placed where it ran, as it always was, and its answer locates the file there.
    @Test(arguments: ["cat Sources/App/Alpha.swift; git status", "cat Sources/App/Alpha.swift || echo 'cd elsewhere'"])
    func anAnswerOnALineThatMovesNowhereLocatesItsFileWhereItRan(line: String) throws {
        let here = try MCPTestRepo.make()

        let lookup = Self.window("sed -n 3,9p Sources/App/Alpha.swift", after: line, cwd: here.path)

        #expect(lookup == .guided(file: "Sources/App/Alpha.swift"))
    }

    /// The placement itself, statement by statement: every literal `cd` in front of the lookups is followed, a line with no move keeps its own directory, and a move that cannot be followed places the answer nowhere.
    @Test
    func theDirectoryIsWhereEveryCdInFrontOfTheLookupsMoved() {
        #expect(Self.answeredFrom("cd /work/a && cd b && sed -n 1,40p Sources/X.swift", from: "/cwd") == "/work/a/b")
        #expect(Self.answeredFrom("cd /work/a; cd /work/b; sed -n 1,40p Sources/X.swift", from: "/cwd") == "/work/b")
        #expect(Self.answeredFrom("cd ../repo && sed -n 1,40p Sources/X.swift", from: "/work/cwd") == "/work/repo")
        #expect(Self.answeredFrom("cd /work/a && sed -n 1,40p Sources/X.swift || cd ..", from: "/cwd") == "/work/a")
        #expect(Self.answeredFrom("sed -n 1,40p Sources/X.swift", from: "/cwd") == "/cwd")
        #expect(Self.answeredFrom("grep -n 'cd x' Sources/X.swift || true", from: "/cwd") == "/cwd")
        #expect(Self.answeredFrom("pushd /work/a && sed -n 1,40p Sources/X.swift", from: "/cwd") == nil)
        #expect(Self.answeredFrom("(cd /work/a && sed -n 1,40p Sources/X.swift)", from: "/cwd") == nil)
        #expect(Self.answeredFrom("cd /work/a && sed -n 1,40p X.swift; cd /work/b && sed -n 1,40p Y.swift", from: "/cwd") == nil)
    }
}
