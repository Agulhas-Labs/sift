//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit` leaves out the sessions recorded in scratch roots, as `usage` and `report` leave out their calls, and says how many.
@Suite(.temporaryDirectories) struct AuditScratchRootTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    private static var answer: String {
        "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(relative) — module: App\n"
            + "imports: Foundation\n\npublic struct Depot — 400 members  :1-402"
    }

    private static var note: String {
        "1 session against scratch roots (temporary, cache or .build directories) not counted"
    }

    /// One session recorded in `/work/Depot` and one recorded in the temporary directory, each with one served digest, and a usage log with a call against each root.
    private static func fixture() throws -> Fixture {
        let directory = try TemporaryDirectory.make("audit-scratch-root")
        let projects = directory.appendingPathComponent("projects")
        for (session, cwd) in [("real", "/work/Depot"), ("probe", directory.path)] {
            let project = projects.appendingPathComponent("-\(session)")
            try writeTranscript(session: session, cwd: cwd, to: project.appendingPathComponent("\(session).jsonl"))
        }
        let log = directory.appendingPathComponent("usage.jsonl")
        try [
            logLine(root: "/work/Depot", session: "real", source: 10000),
            logLine(root: directory.path, session: "probe", source: 5_000_000),
        ].joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return Fixture(projects: projects, log: log)
    }

    /// One served digest recorded in `cwd`, written to `url` as the transcript of `session`.
    private static func writeTranscript(session: String, cwd: String, to url: URL) throws {
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: cwd),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ].map { line -> Data in
            var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            object["sessionId"] = session
            object["timestamp"] = "2026-10-01T10:00:00.500Z"
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: url)
    }

    /// One session in `parent` with one subagent in `agent`, one served digest each.
    private static func mixedFixture(parent: String, agent: String) throws -> Fixture {
        let directory = try TemporaryDirectory.make("audit-scratch-mixed")
        let projects = directory.appendingPathComponent("projects")
        let project = projects.appendingPathComponent("-parent")
        try writeTranscript(session: "parent", cwd: parent, to: project.appendingPathComponent("parent.jsonl"))
        try writeTranscript(session: "parent", cwd: agent, to: project.appendingPathComponent("parent/subagents/agent-a1.jsonl"))
        return Fixture(projects: projects, log: directory.appendingPathComponent("usage.jsonl"))
    }

    private static func logLine(root: String, session: String, source: Int) -> String {
        let entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": "digest", "target": relative, "root": root, "ms": 4, "ok": true,
            "session": session, "outBytes": answer.utf8.count, "srcBytes": source, "via": "hook", "intercepted": "window",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The default leaves the scratch session out of the count and of the logged saving, and the last line says so.
    @Test
    func aScratchSessionIsLeftOutByDefaultWithTheCount() throws {
        let fixture = try Self.fixture()

        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, usageLog: fixture.log, excludingScratch: true)

        #expect(report.hasPrefix("audit — 1 session, 1 Swift lookup"))
        #expect(report.hasSuffix(Self.note))
        let real = 10000 - Self.answer.utf8.count
        #expect(report.contains("\(TokenEstimate.saved(bytes: real)), \(TokenEstimate.basis(bytes: real))"))
    }

    /// Asking for scratch counts both sessions and prints no line.
    @Test
    func includingScratchCountsTheScratchSession() throws {
        let fixture = try Self.fixture()

        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, usageLog: fixture.log)

        #expect(report.hasPrefix("audit — 2 sessions, 2 Swift lookups"))
        #expect(!report.contains("against scratch roots"))
    }

    /// The command takes `--include-scratch` and leaves it off by default.
    @Test
    func theCommandParsesIncludeScratch() throws {
        #expect(try AuditCommand.parse([]).includeScratch == false)
        #expect(try AuditCommand.parse(["--include-scratch"]).includeScratch)
    }

    /// A transcript named explicitly is audited whatever working directory it recorded, so `--transcript` on a scratch session counts it and prints no line.
    @Test
    func aNamedTranscriptIsAuditedEvenFromAScratchRoot() throws {
        let command = try AuditCommand.parse(["--transcript", "probe.jsonl"])
        #expect(command.transcript != nil)
        #expect(!command.includeScratch)

        let fixture = try Self.fixture()
        let probe = fixture.projects.appendingPathComponent("-probe/probe.jsonl")
        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, transcript: probe.path, excludingScratch: AuditCommand.excludesScratch(includeScratch: false, transcript: probe.path))

        #expect(report.hasPrefix("audit — 1 session, 1 Swift lookup"))
        #expect(!report.contains("against scratch roots"))
    }

    /// The replay takes the audit's exclusion: its snapshot drops the scratch session, so its section reads the one session the audit counted.
    @Test
    func theReplayLeavesTheScratchSessionOutToo() async throws {
        let fixture = try Self.fixture()
        let snapshot = TranscriptSnapshot.take(projectsDirectory: fixture.projects, since: nil, transcript: nil)
        defer { snapshot.indexes.close() }
        #expect(snapshot.sessions.count == 2)
        #expect(snapshot.withoutScratch().sessions.map(\.lastPathComponent) == ["real.jsonl"])

        let left = try await Self.replayed(snapshot, fixture, excludingScratch: true)
        let kept = try await Self.replayed(snapshot, fixture, excludingScratch: false)

        #expect(left.contains("1 session against scratch roots (temporary, cache or .build directories) not counted"), "\(left)")
        #expect(left != kept)
        #expect(!kept.contains("against scratch roots"))
        #expect(left.contains("(indexed 1 + recovered 0) / 1 "), "\(left)")
        #expect(kept.contains("(indexed 2 + recovered 0) / 2 "), "\(kept)")
    }

    /// A real session whose subagent recorded a scratch root, and the reverse: the audit and the replay beside it count the same transcripts, each judged by its own working directory.
    @Test(arguments: [(real: "/work/Depot", scratch: true), (real: "/work/Depot", scratch: false)])
    func auditAndReplayCountTheSameTranscriptsWhenTheSubagentDiffers(case example: (real: String, scratch: Bool)) async throws {
        let directory = try TemporaryDirectory.make("audit-scratch-cwd")
        let scratchRoot = directory.path
        let fixture = try Self.mixedFixture(
            parent: example.scratch ? example.real : scratchRoot,
            agent: example.scratch ? scratchRoot : example.real
        )
        let snapshot = TranscriptSnapshot.take(projectsDirectory: fixture.projects, since: nil, transcript: nil)
        defer { snapshot.indexes.close() }

        let report = TranscriptAudit.render(projectsDirectory: fixture.projects, excludingScratch: true)
        let replayed = try await Self.replayed(snapshot, fixture, excludingScratch: true)

        // Where the subagent is the context kept, the header names it beside its session.
        #expect(report.hasPrefix(example.scratch ? "audit — 1 session, 1 Swift lookup" : "audit — 1 session (+1 subagent), 1 Swift lookup"), "\(report)")
        #expect(replayed.contains("(indexed 1 + recovered 0) / 1 "), "\(replayed)")
        #expect(replayed.contains("1 session against scratch roots") == report.contains("1 session against scratch roots"), "\(replayed)")
    }

    /// The command's own report carries the line when it is told to exclude scratch, and not otherwise.
    @Test
    func theCommandsReportCarriesTheLineOnlyWhenExcluding() throws {
        let fixture = try Self.fixture()
        let snapshot = TranscriptSnapshot.take(projectsDirectory: fixture.projects, since: nil, transcript: nil)
        defer { snapshot.indexes.close() }

        let left = AuditCommand.report(snapshot: snapshot, projectsDirectory: fixture.projects, since: nil, usageLog: fixture.log, excludingScratch: true).report
        let kept = AuditCommand.report(snapshot: snapshot, projectsDirectory: fixture.projects, since: nil, usageLog: fixture.log).report

        #expect(left.hasSuffix(Self.note))
        #expect(!kept.contains("against scratch roots"))
    }
}

private extension AuditScratchRootTests {
    static func replayed(_ snapshot: TranscriptSnapshot, _ fixture: Fixture, excludingScratch: Bool) async throws -> String {
        let scratch = try TemporaryDirectory.make("replay")
        return await InPlaceAnswerTests.onItsOwnThread {
            AuditCommand.report(
                snapshot: snapshot,
                projectsDirectory: fixture.projects,
                since: nil,
                replay: true,
                scratch: scratch,
                timeBudget: InPlaceAnswerTests.roomy,
                usageLog: fixture.log,
                excludingScratch: excludingScratch
            ).report
        }
    }

    struct Fixture {
        let projects: URL
        let log: URL
    }
}
