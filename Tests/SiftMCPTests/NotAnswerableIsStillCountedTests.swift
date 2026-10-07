//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup the hook lets through because it has no answer for it is still a lookup that went around the index, and the audit's denominator is where that has to show.
///
/// The two ends are one claim. The hook stopped charging a round trip for a refusal that could only name a call; nothing about that may take the miss out of the share. A lookup allowed here and scored out there would raise the reported share by exactly the misses the change stopped interrupting — the one direction the tally may never round — and would leave an audit saying the index does better the more the hook gives up on.
@Suite(.temporaryDirectories)
struct NotAnswerableIsStillCountedTests {
    private static var pattern: String {
        #"static\|case "#
    }

    private static var file: String {
        "/repo/Sources/App/Depot.swift"
    }

    /// A `Grep` of one Swift file for its declarations: the hook offers no in-place answer for it, so the call goes through as `notAnswerable` — and the same call in a transcript is a cold lookup in the share, neither withheld on worth nor scored out.
    @Test
    func aLookupAllowedAsNotAnswerableIsCountedCold() throws {
        let scratch = try TemporaryDirectory.make("not-answerable")
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let payload: [String: Any] = ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": Self.pattern, "path": Self.file]]
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: "/repo",
            noting: suppressions,
            couldAnswer: { _, _ in true }
        ))

        let outcome = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
            payload: payload,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions
        ) { _, _, _ in .withheld(.notExact) }
        let tally = TranscriptFixture.tally([
            TranscriptTurns.call("Grep", id: "g1", input: ["output_mode": "content", "pattern": Self.pattern, "path": Self.file], turn: "m1", cwd: "/repo"),
        ])

        #expect(outcome.json == nil)
        #expect(outcome.verdict.token == "allowed")
        #expect(outcome.verdict.rule == "notAnswerable")
        #expect(tally.cold == 1)
        #expect(tally.total == 1)
        #expect(tally.withheldOnWorth == 0)
        #expect(tally.textSearches == 0)
    }
}
