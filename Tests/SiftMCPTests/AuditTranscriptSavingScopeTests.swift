//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// `audit --transcript` states the saving of the session it audited, not of every call the usage log holds.
@Suite(.temporaryDirectories) struct AuditTranscriptSavingScopeTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    private static var answer: String {
        "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(relative) — module: App\n"
            + "imports: Foundation\n\npublic struct Depot — 400 members  :1-402"
    }

    private static func fixture() throws -> Fixture {
        let directory = try TemporaryDirectory.make("audit-saving-scope")
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = "public struct Depot {\n" + (0 ..< 400).map { "    func member\($0)() -> Int { \($0) }" }.joined(separator: "\n") + "\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: directory.path),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ].map { line -> Data in
            var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            object["sessionId"] = "audited"
            object["timestamp"] = "2026-10-01T10:00:00.500Z"
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("audited.jsonl")
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        let log = directory.appendingPathComponent("usage.jsonl")
        try [
            logLine(session: "audited", served: answer.utf8.count, source: source.utf8.count),
            logLine(session: "elsewhere", served: 1000, source: 5_000_000),
        ].joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return Fixture(directory: directory, transcript: transcript, log: log, sessionGross: source.utf8.count - answer.utf8.count)
    }

    private static func logLine(session: String, served: Int, source: Int) -> String {
        let entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": "digest", "target": relative, "root": "/repo", "ms": 4, "ok": true,
            "session": session, "outBytes": served, "srcBytes": source,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Another session's call in the same log is not in the audited session's figure, and the line says it is the session's.
    @Test
    func theSavingIsTheAuditedSessionsOwnCalls() throws {
        let fixture = try Self.fixture()
        let projects = fixture.directory.appendingPathComponent("projects")

        let report = TranscriptAudit.render(projectsDirectory: projects, transcript: fixture.transcript.path, usageLog: fixture.log)

        #expect(report.contains("    saving    \(TokenEstimate.saved(bytes: fixture.sessionGross)), \(TokenEstimate.basis(bytes: fixture.sessionGross)): every measured call the usage log holds for this session"))
    }

    /// Without `--transcript` the window's own figure is unchanged: every session's calls count.
    @Test
    func aWindowAuditStillCountsEverySession() throws {
        let fixture = try Self.fixture()
        let projects = fixture.directory.appendingPathComponent("projects")
        let gross = fixture.sessionGross + 5_000_000 - 1000

        let report = TranscriptAudit.render(projectsDirectory: projects, usageLog: fixture.log)

        #expect(report.contains("\(TokenEstimate.saved(bytes: gross)), \(TokenEstimate.basis(bytes: gross)): every measured call the usage log holds for this window"))
    }
}

private extension AuditTranscriptSavingScopeTests {
    struct Fixture {
        let directory: URL
        let transcript: URL
        let log: URL
        let sessionGross: Int
    }
}
