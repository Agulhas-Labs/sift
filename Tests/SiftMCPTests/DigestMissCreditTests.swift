//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A digest that resolved nothing is an answered call (`ok` stays true) that located nothing: no window of the file is excused by it, in the usage log, the replay or the transcript scan, and all three read one definition of a miss (`DigestMiss`).
@Suite(.temporaryDirectories)
struct DigestMissCreditTests {
    private static var session: String {
        "session-miss"
    }

    private static let missAnswers = [
        "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nno symbol named nosuchmember in the index",
        "tree: App\ncould not resolve the path Depot.nosuchmember — Depot has no member nosuchmember; its nearest members:\n  Depot.restock — func — Sources/App/Depot.swift:3-9",
        "tree: App\nno type or member named Depot.nosuch; nearest symbols:\n  Depot — struct — App — Sources/App/Depot.swift:1",
        "tree: App\ncould not resolve the path Shelf.count — count is declared, but not under Shelf:\n  Depot.count — var — Sources/App/Depot.swift:2",
    ]

    private static let servedAnswers = [
        "tree: App\nSources/App/Depot.swift — module: App\n  struct Depot",
        "tree: App\nDepot.restock — func — Sources/App/Depot.swift:3-9\n    func restock() {}",
        "tree: App\n(no declaration spans Sources/App/Depot.swift:99 in Sources/App/Depot.swift); the nearest:\n  Depot.restock — Sources/App/Depot.swift:3-9",
    ]

    /// A repository holding `Sources/App/Depot.swift`, and the file's path.
    private static func repository() throws -> (root: String, file: String) {
        let directory = try TemporaryDirectory.make("miss-credit")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        let sources = directory.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Depot.swift")
        try Data("struct Depot {}\n".utf8).write(to: file)
        return (directory.path, file.path)
    }

    private static func resolve(_: String, atRoot _: String) -> String? {
        "Sources/App/Depot.swift"
    }

    @Test(arguments: missAnswers)
    func theSharedDefinitionReadsEveryMissShape(answer: String) {
        #expect(DigestMiss.isMiss(inAnswer: answer))
    }

    @Test(arguments: servedAnswers)
    func theSharedDefinitionLeavesAServedAnswerAlone(answer: String) {
        #expect(!DigestMiss.isMiss(inAnswer: answer))
    }

    /// The server's own line: the miss is marked, `ok` is not touched, and a line without the field is not a miss.
    @Test
    func theUsageLogMarksAMissAndKeepsItAnswered() throws {
        let file = try TemporaryDirectory.make("miss-log").appendingPathComponent("usage.jsonl")
        let log = UsageLog(fileURL: file)
        log.record(tool: "digest", target: "Depot.nosuchmember", root: "/r", milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 40), miss: true)
        log.record(tool: "digest", target: "Depot", root: "/r", milliseconds: 1, succeeded: true, answer: AnswerBytes(served: 40, source: 900))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }

        #expect(lines[0]["miss"] as? Bool == true)
        #expect(lines[0]["ok"] as? Bool == true)
        #expect(lines[1]["miss"] == nil)
    }

    /// The reported defect: a member digest that served nothing located the file for a window of 200 lines or fewer.
    @Test(arguments: [false, true])
    func aMissedMemberDigestLocatesNoWindow(withSourceBytes: Bool) throws {
        let (root, file) = try Self.repository()
        func line(miss: Bool) -> [String: Any] {
            var entry: [String: Any] = ["tool": "digest", "target": "Depot.nosuchmember", "root": root, "ms": 1, "ok": true, "session": Self.session, "outBytes": 40]
            if withSourceBytes {
                entry["srcBytes"] = 0
            }
            if miss {
                entry["miss"] = true
            }
            return entry
        }
        for (miss, expected) in [(false, true), (true, false)] {
            let log = try DigestedFilesTests.UsageLogFile([line(miss: miss)])
            defer { log.cleanup() }
            #expect(log.digested.locates(file, session: Self.session, agent: nil, resolve: Self.resolve) == expected)
        }
    }

    /// A miss that also lists a heading file is still credited by that heading only where it is not a miss; a miss line credits nothing even beside `located`.
    @Test
    func aMissCreditsNothingEvenWithLocatedFiles() throws {
        let (root, file) = try Self.repository()
        let entry: [String: Any] = ["tool": "digest", "target": "Sources/App/Depot.swift", "root": root, "ms": 1, "ok": true, "session": Self.session, "outBytes": 40, "miss": true, "located": ["Sources/App/Depot.swift"]]
        let log = try DigestedFilesTests.UsageLogFile([entry])
        defer { log.cleanup() }

        #expect(!log.digested.locates(file, session: Self.session, agent: nil, resolve: Self.resolve))
        #expect(!log.digested.contains(file, session: Self.session, agent: nil, resolve: Self.resolve))
    }

    /// The replay reads the answer text: a digest answered with a miss is recorded as one and locates nothing, while a served one still does.
    @Test(arguments: [true, false])
    func theReplayReadsTheAnswerText(missed: Bool) throws {
        let (root, file) = try Self.repository()
        let repository = URL(fileURLWithPath: root)
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: 60, roots: RootDiscovery { _ in repository })
        let payload: [String: Any] = [
            "tool_name": "mcp__sift__digest",
            "tool_input": ["target": "Depot.nosuchmember"],
            "session_id": Self.session,
            TranscriptReplay.answerKey: missed ? Self.missAnswers[0] : Self.servedAnswers[1],
        ]
        hook.answered(payload: payload, cwd: root, at: nil)

        #expect(hook.digested.locates(file, session: Self.session, agent: nil, resolve: Self.resolve) == !missed)
    }

    /// The scan credits what an answer served: a miss locates no file by the member's type, a served answer does.
    @Test(arguments: [true, false])
    func theScanCreditsNothingForAMiss(missed: Bool) {
        let credited = LocatedDigest.credited(
            targets: ["Depot.nosuchmember"],
            whole: true,
            answer: missed ? Self.missAnswers[0] : Self.servedAnswers[1],
            anchor: nil
        )

        #expect(credited.isEmpty == missed)
    }
}
