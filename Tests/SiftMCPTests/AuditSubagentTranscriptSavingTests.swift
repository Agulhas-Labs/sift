//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// `audit --transcript` on a subagent file finds its saving under the parent session and the agent id, or says why it has none.
@Suite(.temporaryDirectories) struct AuditSubagentTranscriptSavingTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    private static var answer: String {
        "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(relative) — module: App\n"
            + "imports: Foundation\n\npublic struct Depot — 400 members  :1-402"
    }

    private static var source: String {
        String(repeating: "x", count: 20000)
    }

    private static func fixture(logAgent: String) throws -> Fixture {
        let directory = try TemporaryDirectory.make("audit-subagent-saving")
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: directory.path),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ].map { line -> Data in
            var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            object["timestamp"] = "2026-10-01T10:00:00.500Z"
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let subagents = directory.appendingPathComponent("projects/-repo/parent-session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcript = subagents.appendingPathComponent("agent-abc123.jsonl")
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        let entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": "digest", "target": relative, "root": "/repo", "ms": 4, "ok": true,
            "session": "parent-session", "agent": logAgent, "outBytes": answer.utf8.count, "srcBytes": source.utf8.count,
        ]
        let log = directory.appendingPathComponent("usage.jsonl")
        let data = try JSONSerialization.data(withJSONObject: entry)
        try (String(bytes: data, encoding: .utf8) ?? "").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return Fixture(projects: directory.appendingPathComponent("projects"), transcript: transcript, log: log)
    }

    /// The row appears, priced from the one call the subagent made.
    @Test
    func theSubagentFileResolvesItsParentSessionAndAgent() throws {
        let fixture = try Self.fixture(logAgent: "abc123")
        let gross = Self.source.utf8.count - Self.answer.utf8.count

        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, transcript: fixture.transcript.path, usageLog: fixture.log)

        #expect(report.contains("    saving    \(TokenEstimate.saved(bytes: gross)), \(TokenEstimate.basis(bytes: gross)): every measured call the usage log holds for this session"))
    }

    /// A log with no call under this agent id gets a one-line reason where the row would be.
    @Test
    func aSubagentWithNoLoggedCallsSaysSo() throws {
        let fixture = try Self.fixture(logAgent: "other")

        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, transcript: fixture.transcript.path, usageLog: fixture.log)

        #expect(report.contains("    saving    none: the usage log holds no measured call for subagent abc123 of session parent-session"))
    }
}

private extension AuditSubagentTranscriptSavingTests {
    struct Fixture {
        let projects: URL
        let transcript: URL
        let log: URL
    }
}
