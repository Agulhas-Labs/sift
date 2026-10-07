//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --transcript` on a `<session>/subagents/agent-<id>.jsonl` file tallies it as a subagent of its parent session, laid out as Claude Code lays it out.
@Suite(.temporaryDirectories) struct AuditSubagentTranscriptTallyTests {
    @Test
    func theSubagentFileIsTalliedUnderItsParentSessionAndAgent() throws {
        let directory = try TemporaryDirectory.make("audit-subagent-tally")
        let subagents = directory.appendingPathComponent("projects/-repo/parent-session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcript = subagents.appendingPathComponent("agent-abc123.jsonl")
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/Depot.swift"], cwd: directory.path),
            TranscriptFixture.indexAnswer(id: "d1", text: "tree: App\nSources/App/Depot.swift — module: App"),
        ]
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)

        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, transcript: transcript.path)
        let scans = TranscriptAudit.sweep(snapshot, since: nil, timeZone: .gmt).scans

        #expect(scans.count == 1)
        #expect(scans.first?.isSubagent == true)
        #expect(scans.first?.session.hasSuffix("projects/-repo/parent-session.jsonl") == true)
        #expect(scans.first?.label.hasSuffix("parent-s · subagent agent-abc123") == true)
        #expect(TranscriptAudit.render(projectsDirectory: directory.appendingPathComponent("projects"), transcript: transcript.path).contains("1 session, 1 Swift lookup"))
    }
}
