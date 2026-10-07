//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A call the hook lets through as `noLookup` after a gate logged it withheld is reported by the replay under the rule logged, not as no lookup at all.
@Suite(.temporaryDirectories) struct ReplaySuppressionRuleTests {
    /// A grep whose output a later stage filters is let through and logged `filteredOutput`, and the replay's verdict names that rule.
    @Test func aFilteredGrepIsReportedUnderTheRuleItIsLoggedUnder() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)

        let verdict = await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = [
                "session_id": "replayed-session",
                "tool_name": "Bash",
                "tool_input": ["command": "grep -rn Depot Sources | sort -u"],
            ]
            return hook.verdict(payload: payload, cwd: root.path, at: nil, decides: true)
        }

        #expect(verdict == ReplayVerdict(token: "allowed", rule: "filteredOutput (logged)"))
    }

    /// A window of a file the context's own digest call located, beside a filtered grep, is counted by `audit --replay` on a still-cold row of the grep's logged rule rather than under `noLookup`.
    @Test func aFilteredGrepBesideALocatedWindowIsCountedUnderItsLoggedRule() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.digestCall(of: "Sources/App/Depot.swift", id: "d1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: "the store is busy"),
            TranscriptAuditReplayTests.call("sed -n 10,20p Sources/App/Depot.swift; grep -rn Depot Sources | sort -u", id: "d2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "d2", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      1  ") }, "\(section)")
        #expect(section.contains("         1  filteredOutput (logged)"), "\(section)")
        #expect(!section.contains { $0.hasSuffix("  noLookup") }, "\(section)")
    }

    /// A window of a file only the replay's own in-place answer located, beside a filtered grep, stays located as it was before the grep's rule was named, so the share's denominator does not move with the label.
    @Test func aLoggedRuleBesideAWindowAnAnswerLocatedStaysLocated() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: true, text: "Use sift digest instead"),
            TranscriptAuditReplayTests.call("sed -n 10,20p Sources/App/Depot.swift; grep -rn Depot Sources | sort -u", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains { $0.hasPrefix("  located         1  ") }, "\(section)")
        #expect(!section.contains("filteredOutput (logged)"), "\(section)")
    }
}

private extension ReplaySuppressionRuleTests {
    /// A `digest` index call of `target` on a line of its own, as the harness writes it.
    static func digestCall(of target: String, id: String, cwd: String, at stamp: String) throws -> Data {
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": cwd,
            "timestamp": stamp,
            "message": ["id": "m-\(id)", "content": [["type": "tool_use", "id": id, "name": "mcp__sift__digest", "input": ["target": target]]]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
