//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A refusal is priced by the round trip it cost: when it was the only call in its assistant turn, the next turn re-sent the whole context, and that turn's `message.usage` says how much.
///
/// Every line here is shaped as the harness writes it (``TranscriptTurns``), so the pre-filter meets the lines a real transcript holds — a turn that opens with text, a result that names no tool.
@Suite(.temporaryDirectories)
struct RefusalRoundTripTests {
    private static var grep: String {
        "grep -n 'func go' /repo/Sources/App/Alpha.swift"
    }

    private static var refusal: String {
        TranscriptFixture.refusal(call: "digest Alpha.go")
    }

    /// A refused lookup alone in turn `turn`, as the call and the hook's refusal of it.
    private static func refused(id: String, turn: String, command: String = grep) -> [Data] {
        [
            TranscriptTurns.call("Bash", id: id, input: ["command": command], turn: turn),
            TranscriptTurns.result(id: id, text: refusal, isError: true),
        ]
    }

    /// Alone in its turn, a refusal is charged what the next turn re-sent: its input tokens, cache reads and cache writes — seen even where that turn opens on a line of text, which carries none of a call's markers.
    @Test
    func aRefusalAloneInItsTurnIsPricedByWhatTheNextTurnReSent() {
        let next = TranscriptTurns.Usage(input: 3, cacheRead: 150_000, cacheCreation: 2000)
        let lines = Self.refused(id: "c1", turn: "m1") + [TranscriptTurns.text("Taking the digest instead.", turn: "m2", usage: next)]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.refusals == 1)
        #expect(tally.soloRefusals == 1)
        #expect(tally.resentTokens == 152_003)
    }

    /// A refusal that shared its turn with another call cost no round trip of its own: the next turn was coming for the other call's result anyway, whatever tool it was.
    @Test
    func aRefusalThatSharedItsTurnIsNotCharged() {
        let next = TranscriptTurns.Usage(input: 3, cacheRead: 150_000)
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": Self.grep], turn: "m1"),
            TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Beta.swift"], turn: "m1"),
            TranscriptTurns.result(id: "c1", text: Self.refusal, isError: true),
            TranscriptTurns.result(id: "e1", text: "The file has been updated."),
            TranscriptTurns.text("Next.", turn: "m2", usage: next),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.refusals == 1)
        #expect(tally.soloRefusals == 0)
        #expect(tally.resentTokens == 0)
    }

    /// A refusal the transcript ends on has re-sent nothing yet, and is charged nothing.
    @Test
    func aRefusalTheTranscriptEndsOnIsNotCharged() {
        let tally = TranscriptFixture.tally(Self.refused(id: "c1", turn: "m1"))

        #expect(tally.refusals == 1)
        #expect(tally.soloRefusals == 0)
    }

    /// Each round trip is priced by its own next turn, so two refusals at two sizes of context are two different costs.
    @Test
    func eachRoundTripIsPricedByItsOwnNextTurn() {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Beta.swift", "limit": 10], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 80000))]
            + Self.refused(id: "c2", turn: "m3", command: "grep -n 'func stop' /repo/Sources/App/Alpha.swift")
            + [TranscriptTurns.text("Done.", turn: "m4", usage: TranscriptTurns.Usage(cacheRead: 700_000))]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.soloRefusals == 2)
        #expect(tally.resentTokens == 80002 + 700_002)
    }

    /// `audit` shows what the refusals cost: how many were alone in their turn, the total those re-sent, and the costliest few with the context each was given in.
    @Test
    func theAuditPricesTheRefusalsAndListsTheCostliest() throws {
        let session = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.text("Next.", turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 700_000))]
            + [
                TranscriptTurns.call("Bash", id: "c2", input: ["command": "grep -n 'func stop' /repo/Sources/App/Alpha.swift"], turn: "m3"),
                TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Beta.swift"], turn: "m3"),
                TranscriptTurns.result(id: "c2", text: Self.refusal, isError: true),
                TranscriptTurns.text("Next.", turn: "m4", usage: TranscriptTurns.Usage(cacheRead: 90000)),
            ]
        let subagent = Self.refused(id: "c3", turn: "s1") + [TranscriptTurns.text("Next.", turn: "s2", usage: TranscriptTurns.Usage(cacheRead: 80000))]
        let root = try Self.projects(session: session, subagent: subagent)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)
        let lines = report.split(separator: "\n").map(String.init)
        let costliest = try #require(lines.firstIndex { $0.contains("costliest:") })

        #expect(report.contains("3 refusals, 2 alone in their turn — each of those cost a round trip that re-sent the whole context:"))
        #expect(report.contains("  78,004 tokens input-equivalent re-sent (780,004 tokens raw: 4 tokens uncached, 780,000 tokens cache reads, 0 tokens cache writes) — each next turn's input, cache reads and cache writes, from its message.usage"))
        #expect(report.contains("  1 not charged one: shared a turn with other calls, or were the context's last word"))
        #expect(lines[costliest + 1].hasPrefix("    70,002 tokens"))
        #expect(lines[costliest + 2].hasPrefix("    8,002 tokens"))
        #expect(lines[costliest + 2].contains("agent-0"))
    }

    /// A session transcript and one subagent's, in a `projects/<project>/` tree for the audit to sweep.
    private static func projects(session: [Data], subagent: [Data]) throws -> URL {
        let root = try TemporaryDirectory.make("roundtrip").appendingPathComponent("roundtrip")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        let agents = directory.appendingPathComponent("11112222-3333/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(session.flatMap { $0 + [0x0A] }).write(to: directory.appendingPathComponent("11112222-3333.jsonl"))
        try Data(subagent.flatMap { $0 + [0x0A] }).write(to: agents.appendingPathComponent("agent-0.jsonl"))
        return root
    }
}
