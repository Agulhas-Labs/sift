//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A `sift digest` run from Bash behind a literal `cd` is credited to the repository the `cd` moved to, so a ranged `Read` of a range it located is let through rather than answered with a digest again.
@Suite(.temporaryDirectories) struct CdDigestLedgerTests {
    /// The commonest shape a subagent writes, `cd <worktree> && sift digest X`, run from another repository: the ranged `Read` of the file it located is no lookup.
    @Test(arguments: ["cd %@ && sift digest Shell", "cd %@; sift digest Shell", "cd %@ && git status && sift digest Shell"])
    func aDigestBehindACdLocatesTheFileInTheRepositoryItMovedTo(line: String) async throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try fixture.lengthen()
        try await fixture.index()
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        _ = PreToolUseCommand.adviceTaken(
            session: "s1",
            context: fixture.context("s1"),
            payload: ["tool_name": "Bash", "tool_input": ["command": String(format: line, fixture.repo.path)], "agent_id": "a1"],
            cwd: elsewhere.path,
            ledger: fixture.ledger,
            callers: CallAttribution(directory: fixture.stores.appendingPathComponent("callers"))
        )

        #expect(try fixture.verdict(fixture.classified(rangedReadFrom: 1)).line == "allowed\t\tnoLookup")
    }

    /// The same digest with no `cd` in front, run from the other repository, locates nothing in this one: the ranged `Read` is still answered.
    @Test func aDigestRunInAnotherRepositoryLocatesNothingHere() async throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try fixture.lengthen()
        try await fixture.index()
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        _ = PreToolUseCommand.adviceTaken(
            session: "s1",
            context: fixture.context("s1"),
            payload: ["tool_name": "Bash", "tool_input": ["command": "sift digest Shell"], "agent_id": "a1"],
            cwd: elsewhere.path,
            ledger: fixture.ledger,
            callers: CallAttribution(directory: fixture.stores.appendingPathComponent("callers"))
        )

        #expect(try fixture.verdict(fixture.classified(rangedReadFrom: 1)).token == "in-place")
    }

    /// A move the hook cannot follow, into another repository, from this one: crediting the line's own directory would record `Shell` against this repository's `Shell.swift`, so it credits nothing and the ranged `Read` is still answered.
    @Test(arguments: [
        "(cd {ELSEWHERE} && sift digest Shell)",
        "pushd {ELSEWHERE} && sift digest Shell",
        "cd - && sift digest Shell",
        "echo $(cd {ELSEWHERE} && sift digest Shell)",
        "cd {ELSEWHERE} | sift digest Shell",
        "cd {ELSEWHERE} || true && sift digest Shell",
    ])
    func aDigestBehindAMoveNotFollowedCreditsNothing(line: String) async throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        let verdict = try await Self.rangedReadVerdict(after: line, from: fixture.repo, fixture: fixture, elsewhere: elsewhere)

        #expect(verdict.token == "in-place")
    }

    /// Every move the hook follows still credits the repository it lands in, run from another one: an absolute or relative path, `cd ..` then down, a quoted path, several moves, a `--root` after the move, a second `cd` statement after a first, and a digest piping its output on.
    @Test(arguments: [
        "cd {REPO} && sift digest Shell",
        "cd {REPO} && sift digest Shell | head -40",
        "cd {REPO} && sift digest Shell 2>&1 | head -40",
        "cd {RELATIVE} && sift digest Shell",
        "cd .. && cd {UP} && sift digest Shell",
        "cd '{REPO}' && sift digest Shell",
        "cd / && cd {REPO} && git status && sift digest Shell",
        "cd {REPO}/Sources && sift digest --root .. Shell",
        "cd {ELSEWHERE} && git status; cd {REPO} && sift digest Shell",
    ])
    func aDigestBehindAFollowedMoveStillCreditsWhereItLands(line: String) async throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        let verdict = try await Self.rangedReadVerdict(after: line, from: elsewhere, fixture: fixture, elsewhere: elsewhere)

        #expect(verdict.line == "allowed\t\tnoLookup")
    }

    /// A quoted move into a repository whose path holds a space is followed like any other.
    @Test func aQuotedMoveWithASpaceIsFollowed() async throws {
        let spaced = try MCPTestRepo.make(at: TemporaryDirectory.make("mcp").appendingPathComponent("with space"), declaring: "Shell")
        let fixture = try AlreadyDigestedReadTests.Fixture(repo: spaced)
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        let verdict = try await Self.rangedReadVerdict(after: "cd \"{REPO}\" && sift digest Shell", from: elsewhere, fixture: fixture, elsewhere: elsewhere)

        #expect(verdict.line == "allowed\t\tnoLookup")
    }

    /// A line with no move on it credits the directory it runs in, whatever else its shape: a pipe, a substitution or a statement behind `||`.
    @Test(arguments: ["sift digest Shell | head -40", "echo $(sift digest Shell)", "false || sift digest Shell"])
    func aDigestWithNoMoveCreditsItsOwnDirectory(line: String) async throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        let elsewhere = try MCPTestRepo.make(declaring: "Other")

        let verdict = try await Self.rangedReadVerdict(after: line, from: fixture.repo, fixture: fixture, elsewhere: elsewhere)

        #expect(verdict.line == "allowed\t\tnoLookup")
    }

    /// The hook's verdict on a ranged `Read` of `Shell.swift` from line 1, once it has seen `line` run from `cwd` — `{REPO}`, `{ELSEWHERE}`, `{RELATIVE}` and `{UP}` spelling the fixture's repository, the other one, the fixture's reached from the other, and from the other's parent.
    private static func rangedReadVerdict(after line: String, from cwd: URL, fixture: AlreadyDigestedReadTests.Fixture, elsewhere: URL) async throws -> PreToolUseCommand.Verdict {
        try fixture.lengthen()
        try await fixture.index()
        let parent = elsewhere.deletingLastPathComponent()
        let command = line.replacingOccurrences(of: "{ELSEWHERE}", with: elsewhere.path)
            .replacingOccurrences(of: "{RELATIVE}", with: BatchedReadNoteTests.relative(fixture.repo, from: elsewhere))
            .replacingOccurrences(of: "{UP}", with: BatchedReadNoteTests.relative(fixture.repo, from: parent))
            .replacingOccurrences(of: "{REPO}", with: fixture.repo.path)
        _ = PreToolUseCommand.adviceTaken(
            session: "s1",
            context: fixture.context("s1"),
            payload: ["tool_name": "Bash", "tool_input": ["command": command], "agent_id": "a1"],
            cwd: cwd.path,
            ledger: fixture.ledger,
            callers: CallAttribution(directory: fixture.stores.appendingPathComponent("callers"))
        )
        return try fixture.verdict(fixture.classified(rangedReadFrom: 1))
    }
}
