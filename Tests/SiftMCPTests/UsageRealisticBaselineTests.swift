//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `usage` and `audit` say what they counted in the same terms: a session with its subagents beside it, and each names what the other counts.
@Suite(.temporaryDirectories)
struct UsageRealisticBaselineTests {
    /// A usage log of `objects`, one line each, in a fresh temporary directory.
    static func writeLog(_ objects: [[String: Any]]) throws -> URL {
        let file = try TemporaryDirectory.make("usage-baseline").appendingPathComponent("usage.jsonl")
        let lines = try objects.map { try String(bytes: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8) ?? "" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// One logged call: a tool, its target, and the session and subagent it came from.
    static func call(_ tool: String, target: String = "Depot", session: String? = "parent", agent: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["tool": tool, "target": target, "root": "/repo/a", "ms": 5, "ok": true, "ts": "2026-10-08T10:00:00Z"]
        object["session"] = session
        object["agent"] = agent
        return object
    }

    @Test
    func usageNamesTheSessionWithItsSubagentsBesideIt() throws {
        let file = try Self.writeLog([
            Self.call("digest"),
            Self.call("where", agent: "agent-one"),
            Self.call("search", agent: "agent-two"),
            Self.call("digest", session: nil),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("usage — 0 failures, 4 calls, 2026-10-08 → 2026-10-08, from 1 session (+2 subagents) and 1 call naming no session"), "\(report)")
        #expect(report.contains("sift audit counts the transcripts' Swift lookups by any route instead"), "\(report)")
    }

    /// One call the hook answered in place, measured, with what it intercepted where the line records it.
    static func hookAnswer(_ target: String, served: Int, source: Int, intercepted: String?) -> [String: Any] {
        var object = call("digest", target: target)
        object["via"] = "hook"
        object["outBytes"] = served
        object["srcBytes"] = source
        object["intercepted"] = intercepted
        object["readBytes"] = intercepted == "file" ? source : nil
        return object
    }

    @Test
    func onlyAnInterceptedReadIsPricedAndTheHeadlineSaysWhatItWasPricedOn() throws {
        let file = try Self.writeLog([
            Self.hookAnswer("Sources/App/Depot.swift", served: 1000, source: 9000, intercepted: "file"),
            Self.hookAnswer("Sources/App/Depot.swift:10-60", served: 500, source: 2500, intercepted: "window"),
            Self.hookAnswer("Sources/App/Depot.swift", served: 400, source: 9000, intercepted: "other"),
            Self.hookAnswer("Sources/App/Depot.swift", served: 400, source: 9000, intercepted: nil),
            {
                var digest = Self.call("digest", target: "Sources/App/Depot.swift")
                digest["outBytes"] = 800
                digest["srcBytes"] = 9000
                return digest
            }(),
            Self.call("where"),
        ])

        let savings = try #require(try UsageScan.load(fileURL: file).get().savings)

        #expect(savings.total.calls == 2)
        #expect(savings.total.saved == 8000 + 2000)
        #expect(savings.headline == "~2.5k tokens saved on 2 intercepted reads (file or window asked for − answer served); 4 other calls unpriced — 10 kB gross at 4 bytes a token")
        #expect(savings.unpriced?.note.hasSuffix("; 1 of them hook answers logged before the field that prices one") == true, "\(savings.unpriced?.note ?? "")")
    }

    /// A hook answer the context then read anyway is taken back: unpriced, and named as read anyway in the headline's unpriced clause.
    @Test
    func anAnswerReadAnywayIsUnpricedAndTheHeadlineSaysSo() throws {
        let answer = { (call: String) in
            var object = Self.hookAnswer("Sources/App/Depot.swift", served: 1000, source: 9000, intercepted: "file")
            object["call"] = call
            return object
        }
        let file = try Self.writeLog([
            answer("toolu_1"),
            answer("toolu_2"),
            ["ts": "2026-10-08T10:01:00Z", "readAnyway": "toolu_1", "target": "Sources/App/Depot.swift", "session": "parent"],
            Self.call("where"),
        ])

        let scan = try UsageScan.load(fileURL: file).get()
        let savings = try #require(scan.savings)

        #expect(scan.malformed == 0)
        #expect(savings.total.calls == 1)
        #expect(savings.total.saved == 8000)
        #expect(savings.headline == "~2.0k tokens saved on 1 intercepted read (file or window asked for − answer served); 1 read anyway, 1 other call unpriced — 8.0 kB gross at 4 bytes a token")
        #expect(savings.unpriced?.note.hasSuffix("; 1 answered in place by the hook and then read anyway") == true, "\(savings.unpriced?.note ?? "")")
    }

    /// The writer records what the hook intercepted beside `via`, and leaves the field off every line that has none.
    @Test
    func theWriterRecordsWhatTheHookIntercepted() throws {
        let log = try TemporaryDirectory.make("usage-intercepted").appendingPathComponent("usage.jsonl")
        let usage = UsageLog(fileURL: log)
        usage.record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 5, succeeded: true,
            answer: AnswerBytes(served: 100, source: 900), session: "s1", via: "hook", intercepted: "file"
        )
        usage.record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 5, succeeded: true,
            answer: AnswerBytes(served: 100, source: 900), session: "s1"
        )

        let objects = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }

        #expect(objects.map { $0["intercepted"] as? String } == ["file", nil])
        #expect(objects.map { $0["via"] as? String } == ["hook", nil])
    }

    /// The hook classifies what each command asked for: a whole file or a window of lines, each with an observed counterfactual.
    @Test(arguments: [
        ("cat Sources/App/Depot.swift", InPlaceAnswerer.Interception.file),
        ("sed -n '2,180p' Sources/App/Depot.swift", .window),
    ])
    func theHookClassifiesAReadByWhatItAskedFor(command: String, expected: InPlaceAnswerer.Interception) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(answered.calls.map(\.intercepted) == [expected])
    }

    /// A grep the hook answered stands in for output nobody saw, so it is classed as neither.
    @Test
    func aGrepIsClassedAsOther() async throws {
        let root = try await DeclarationGrepDigestTests.repository()

        let answered = try #require(try await InPlaceAnswerTests.answered(#"grep -n 'func \|@Test' Sources/App/Checks.swift"#, in: root))

        #expect(answered.calls.map(\.intercepted) == [.other])
    }

    @Test
    func aLogOfVoluntaryCallsStatesNoSaving() throws {
        var digest = Self.call("digest", target: "Sources/App/Depot.swift")
        digest["outBytes"] = 800
        digest["srcBytes"] = 9000
        let file = try Self.writeLog([digest, Self.call("where")])

        #expect(try UsageScan.load(fileURL: file).get().savings == nil)
        #expect(!UsageReport.render(fileURL: file).contains("tokens saved"))
    }

    @Test
    func auditNamesTheSubagentsBesideTheirSessionAndWhatSiftServed() throws {
        let directory = try TemporaryDirectory.make("audit-session-count")
        let project = directory.appendingPathComponent("projects/-repo")
        let subagents = project.appendingPathComponent("parent-session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let digest = { (id: String) in
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: id, input: ["target": "Sources/App/Depot.swift"], cwd: directory.path),
                TranscriptFixture.indexAnswer(id: id, text: "tree: App\nSources/App/Depot.swift — module: App"),
            ]
        }
        let write = { (lines: [Data], file: URL) in try Data(lines.flatMap { $0 + [0x0A] }).write(to: file) }
        try write(digest("p1"), project.appendingPathComponent("parent-session.jsonl"))
        try write(digest("a1"), subagents.appendingPathComponent("agent-one.jsonl"))
        try write(digest("b1"), subagents.appendingPathComponent("agent-two.jsonl"))

        let report = TranscriptAudit.render(projectsDirectory: directory.appendingPathComponent("projects"), since: nil, timeZone: .gmt)

        #expect(report.hasPrefix("audit — 1 session (+2 subagents), 3 Swift lookups by any route, 3 served by sift"), "\(report)")
    }
}
