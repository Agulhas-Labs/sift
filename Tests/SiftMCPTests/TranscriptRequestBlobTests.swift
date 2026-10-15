//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Request-record lines repeat tool calls already written elsewhere in the transcript, so no reader that counts or judges calls may take them for new ones.
@Suite(.temporaryDirectories)
struct TranscriptRequestBlobTests {
    /// A request-record line as Claude Code writes it: no timestamp, and a message whose content repeats earlier blocks.
    private static func blob(repeating blocks: [[String: Any]]) -> Data {
        let object: [String: Any] = [
            "type": "api-request-blob",
            "sessionId": "11112222-3333",
            "hash": "abc123",
            "message": ["role": "assistant", "content": blocks],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func readBlock(id: String, path: String) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": "Read", "input": ["file_path": path]]
    }

    private static func resultBlock(id: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": "struct A {}"]
    }

    private static func write(_ lines: [Data], named name: String) throws -> URL {
        let directory = try TemporaryDirectory.make(name)
        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        return transcript
    }

    private static func auditHeader(_ lines: [Data]) throws -> String {
        let directory = try TemporaryDirectory.make("blob-audit")
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: project.appendingPathComponent("session.jsonl"))
        let report = TranscriptAudit.render(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, timeZone: .gmt)
        return String(report.prefix { $0 != "\n" })
    }

    private static let twoCalls: [Data] = [
        TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/A.swift"]),
        TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct A {}"),
        TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/B.swift"]),
        TranscriptFixture.toolResult(id: "r2", isError: false, text: "struct B {}"),
    ]

    /// Two real calls and a request record repeating the first call and its result: two lookups, not three.
    @Test func aRequestRecordRepeatingACallAddsNoLookup() throws {
        let repeated = Self.blob(repeating: [Self.readBlock(id: "r1", path: "/repo/Sources/App/A.swift"), Self.resultBlock(id: "r1")])

        let header = try Self.auditHeader(Self.twoCalls + [repeated])

        #expect(header == "audit — 1 session, 2 Swift lookups by any route, 0 served by sift (0%)")
    }

    /// The replay judges each call once, whichever line repeats it.
    @Test func theReplayJudgesARepeatedCallOnce() throws {
        let directory = try TemporaryDirectory.make("blob-replay-cwd")
        let file = directory.appendingPathComponent("Catalogue.swift").path
        let repeated = Self.blob(repeating: [Self.readBlock(id: "r1", path: file)])
        let lines = [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": file], cwd: directory.path),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Catalogue {}"),
            repeated,
        ]
        let transcript = try Self.write(lines, named: "blob-replay")
        let hook = CountingHook()
        let probes = ReplayProbes(since: nil, until: nil, timeZone: .gmt, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, memberExists: { _, _, _ in true })

        let context = TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: hook)

        #expect(context.tally.cold == 1)
        #expect(hook.judged == 1)
    }

    /// A repeated edit and its result must not move the file to the end of the order, which would put it after a later run.
    @Test func theEditsScanKeepsTheOrderWhenARequestRecordRepeatsAnEdit() throws {
        func edit(_ id: String, _ path: String) -> Data {
            TranscriptFixture.toolUse("Edit", id: id, input: ["file_path": path], cwd: "/repo")
        }
        let repeated = Self.blob(repeating: [
            ["type": "tool_use", "id": "e1", "name": "Edit", "input": ["file_path": "/repo/Sources/A.swift"]],
            Self.resultBlock(id: "e1"),
        ])
        let transcript = try Self.write([
            edit("e1", "/repo/Sources/A.swift"), TranscriptFixture.toolResult(id: "e1", isError: false),
            edit("e2", "/repo/Sources/B.swift"), TranscriptFixture.toolResult(id: "e2", isError: false),
            repeated,
        ], named: "blob-edits")

        let files = BuildInputEditsSinceGreenRun.files(inTranscript: transcript, skippingSidechains: false)

        #expect(files == ["/repo/Sources/A.swift", "/repo/Sources/B.swift"])
    }

    /// The follow-up scan attributes a ranged read once, however many lines repeat it.
    @Test func theDigestFollowUpScanCountsARepeatedReadOnce() {
        let answer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        CrateData — LibCore — Sources/Models/CrateData.swift:9-54 (+1 extension)
        package struct CrateData: Equatable

        stored properties:
          package let width: Double?  :11  /// Bay width in metres.

        members:
          package init(width: Double?)  :33-53

        extension CrateData (package) — Sources/Models/CrateData.swift:56-134
          struct CrateSet: Identifiable, Equatable — 5 members  :58-70
          enum Finish: Int, Equatable — 8 cases/members: matte gloss satin  :103-133
        """
        let digestAnswer: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": "d1", "content": [["type": "text", "text": answer]]]]],
        ]
        let read = TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 58, "limit": 13])
        var scan = DigestFollowUpScan()
        scan.consume(line: TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "CrateData"]))
        scan.consume(line: (try? JSONSerialization.data(withJSONObject: digestAnswer)) ?? Data())
        scan.consume(line: read)
        let repeatedRead: [String: Any] = [
            "type": "tool_use", "id": "r1", "name": "Read",
            "input": ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 58, "limit": 13],
        ]
        scan.consume(line: Self.blob(repeating: [repeatedRead]))

        #expect(scan.result.collapsedNested == 1)
    }
}

extension TranscriptRequestBlobTests {
    /// A hook that only counts the calls it is asked about.
    private final class CountingHook: ReplayHook {
        private(set) var judged = 0

        func verdict(payload _: [String: Any], cwd _: String, at _: Date?, decides _: Bool) -> ReplayVerdict? {
            judged += 1
            return ReplayVerdict(token: "allowed", rule: "noLookup")
        }

        func answered(payload _: [String: Any], cwd _: String, at _: Date?) {}

        func locatedOnlyByAnswers(_: String, payload _: [String: Any]) -> Bool {
            false
        }
    }
}
