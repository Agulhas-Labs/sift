//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// No denial swallows a leg's output: a line of reads is answered only where the answer covers every read on it, and runs otherwise, with the note naming the call for what was not held — where some of its windows are of a file this context holds, or where a leg is one the ledger already allows a re-run of.
@Suite(.temporaryDirectories)
struct HeldWindowLineTests {
    private static var shellWindows: String {
        "sed -n '1,30p' Sources/App/Shell.swift; sed -n '40,60p' Sources/App/Shell.swift"
    }

    private static var otherWindow: String {
        "sed -n '5,40p' Sources/App/Other.swift"
    }

    /// Two windows of a file whose digest this context holds beside a window of another file: through either record of the digest, the held windows are dropped and the line runs with the note naming the call for the other file (`otherStatementsRun`), rather than being denied with the other file's digest alone.
    ///
    /// Not set aside whole as `noLookup`, which would lose the note and the audit's batched row for the read that was not held.
    @Test(arguments: [false, true])
    func aLineWithAHeldFilesWindowsIsLetThrough(throughTheUsageLog: Bool) throws {
        let fixture = try Self.fixture()
        let command = "\(Self.shellWindows); \(Self.otherWindow)"
        if !throughTheUsageLog {
            fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        }

        let judged = try Self.judged(command, in: fixture, located: throughTheUsageLog)

        #expect(judged.line == "allowed\t\totherStatementsRun")
        #expect(judged.json?.contains("permissionDecision") == false)
    }

    /// The controls: a held file's window alone is still no lookup, and an unheld file's window alone, or a line of windows of files none of which is held, is still answered.
    @Test
    func windowsWithNothingHeldBesideThemAreJudgedAsBefore() throws {
        let fixture = try Self.fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let cold = try Self.fixture()

        #expect(try Self.judged("sed -n '1,30p' Sources/App/Shell.swift", in: fixture).line == "allowed\t\tnoLookup")
        #expect(try Self.judged(Self.otherWindow, in: fixture).line.hasPrefix("in-place\t"))
        #expect(try Self.judged("\(Self.shellWindows); \(Self.otherWindow)", in: cold).line.hasPrefix("in-place\t"))
    }

    /// A held file's window beside a grep leaves the grep the lookup, judged on its own, but the window still prints, so the line runs, naming the call that answers the grep, rather than being denied with an answer to the grep alone.
    @Test
    func aHeldWindowBesideAGrepLetsTheLineRun() throws {
        let fixture = try Self.fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])

        let judged = try Self.judged("sed -n '1,30p' Sources/App/Shell.swift; grep -rn part1 Sources", in: fixture)

        #expect(judged.line == "allowed\t\totherStatementsRun")
        #expect(judged.json?.contains("permissionDecision") == false)
    }

    /// A leg whose re-run the ledger already allows still prints its lines beside a new lookup, so the line runs, naming the call that answers the new one, rather than being denied with an answer that swallows the allowed leg's output.
    @Test
    func aLineWithAnAllowedLegIsLetThrough() throws {
        let fixture = try Self.fixture()
        let first = try Self.judged(Self.otherWindow, in: fixture, session: "s2")
        #expect(first.line.hasPrefix("in-place\t"))

        let judged = try Self.judged("\(Self.otherWindow); sed -n '1,30p' Sources/App/Shell.swift", in: fixture, session: "s2")

        #expect(judged.line == "allowed\t\totherStatementsRun")
        #expect(judged.json?.contains("permissionDecision") == false)
    }

    /// A repository whose `Shell.swift` and `Other.swift` are both long enough to be answered.
    static func fixture() throws -> AlreadyDigestedReadTests.Fixture {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try fixture.lengthen()
        try fixture.lengthen("Other")
        return fixture
    }

    /// The hook's output and verdict line on `command`, run in the repository in `session`, agent `a1` — classified with the re-runs the ledger allows, then decided — with an answerer that answers every reading but one leaving other statements to print, as the real one does.
    ///
    /// `located` puts a digest of `Shell.swift` on the usage log the classification reads.
    static func judged(
        _ command: String,
        in fixture: AlreadyDigestedReadTests.Fixture,
        session: String = "s1",
        located: Bool = false
    ) throws -> (line: String, json: String?) {
        let digest: [[String: Any]] = [["tool": "digest", "target": "Sources/App/Shell.swift", "root": fixture.repo.path, "ms": 3, "ok": true, "session": session, "agent": "a1", "outBytes": 900, "srcBytes": 12000]]
        let usage = try DigestedFilesTests.UsageLogFile(located ? digest : [])
        defer { usage.cleanup() }
        let payload: [String: Any] = ["session_id": session, "agent_id": "a1", "tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_h1"]
        let context = fixture.context(session)
        guard let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: fixture.repo.path,
            noting: fixture.suppressions,
            digested: usage.digested,
            couldAnswer: { _, _ in true },
            allowed: { fixture.ledger.rerunsAllowed(session: context.key, among: $0) }
        ) else {
            return (PreToolUseCommand.Verdict(token: "allowed", rule: "noLookup").line, nil)
        }
        let answered = InPlaceAnswerer.Answered(
            reason: "answered",
            calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Other.swift", bytes: WorthAnsweringFixture.answerBytes)],
            root: fixture.repo.path,
            milliseconds: 1
        )
        let outcome = PreToolUseCommand.outcome(
            to: lookup,
            session: session,
            context: context,
            payload: payload,
            cwd: fixture.repo.path,
            ledger: fixture.ledger,
            usage: UsageLog(fileURL: fixture.stores.appendingPathComponent("usage.jsonl")),
            suppressions: fixture.suppressions,
            answerer: { match, _, _ in match.runsOtherStatements ? .withheld(.otherStatementsRun) : .answered(answered) },
            couldAnswer: { _, _ in true }
        )
        return (outcome.verdict.line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).prefix(3).joined(separator: "\t"), outcome.json)
    }
}
