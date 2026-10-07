//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A digest the MCP tool or the CLI served, whose file the same context then read whole anyway, is that read in the share: read whole after its digest, a miss.
@Suite(.temporaryDirectories)
struct DigestReadAnywayTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    /// A checkout holding one file well above the digest floor, and the digest answer the index would serve for it.
    private static func checkout() throws -> Checkout {
        let directory = try TemporaryDirectory.make("digest-read-anyway")
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = (0 ..< 400).map { "    func member\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        let source = "public struct Depot {\n\(body)\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let answer = "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(relative) — module: App\n"
            + "imports: Foundation\n\npublic struct Depot — 400 members  :1-402"
        return Checkout(directory: directory, file: file.path, source: source.utf8.count, answer: answer)
    }

    /// The usage-log line the server writes for that digest, under this session.
    private static func usageLine(served: Int, source: Int) -> String {
        let entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": "digest", "target": relative, "root": "/repo", "ms": 4, "ok": true,
            "session": "session", "outBytes": served, "srcBytes": source,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The tally the audit scores the lines at, with the usage log the server would have written beside them.
    private static func tally(_ lines: [Data], usage: [String], in directory: URL) throws -> TranscriptTally {
        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        let usageLog = directory.appendingPathComponent("usage.jsonl")
        try (usage.joined(separator: "\n") + "\n").write(to: usageLog, atomically: true, encoding: .utf8)
        return TranscriptFixture.scored(transcript: transcript)
    }

    private static func mcpDigest(answer: String, cwd: String) -> [Data] {
        [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: cwd),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ]
    }

    private static func read(_ file: String, id: String, cwd: String, input: [String: Any] = [:]) -> [Data] {
        [
            TranscriptFixture.toolUse("Read", id: id, input: ["file_path": file].merging(input) { $1 }, cwd: cwd),
            TranscriptFixture.toolResult(id: id, isError: false, text: "1\tpublic struct Depot {"),
        ]
    }

    /// The miss stays in the share.
    @Test
    func anMCPDigestReadWholeAfterwardsSavesNothing() throws {
        let checkout = try Self.checkout()
        let lines = Self.mcpDigest(answer: checkout.answer, cwd: checkout.directory.path) + Self.read(checkout.file, id: "r1", cwd: checkout.directory.path)
        let tally = try Self.tally(lines, usage: [Self.usageLine(served: checkout.answer.utf8.count, source: checkout.source)], in: checkout.directory)

        #expect(tally.readWholeAfterDigest == 1)
        #expect(tally.shareText == "50%")
        #expect(tally.total == 2)
    }

    /// The same for a digest the CLI served from a Bash line and a whole read of its file afterwards.
    @Test
    func aCLIDigestReadWholeAfterwardsSavesNothing() throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path
        let lines = [
            TranscriptFixture.toolUse("Bash", id: "c1", input: ["command": "sift digest \(Self.relative)"], cwd: cwd),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: checkout.answer),
        ] + Self.read(checkout.file, id: "r1", cwd: cwd)
        let tally = try Self.tally(lines, usage: [Self.usageLine(served: checkout.answer.utf8.count, source: checkout.source)], in: checkout.directory)

        #expect(tally.readWholeAfterDigest == 1)
    }

    /// A ranged read the digest located is the loop working.
    @Test
    func aGuidedWindowAfterwardsKeepsTheSaving() throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path
        let lines = Self.mcpDigest(answer: checkout.answer, cwd: cwd) + Self.read(checkout.file, id: "r1", cwd: cwd, input: ["offset": 10, "limit": 20])
        let tally = try Self.tally(lines, usage: [Self.usageLine(served: checkout.answer.utf8.count, source: checkout.source)], in: checkout.directory)

        #expect(tally.guided == 1)
    }
}

private extension DigestReadAnywayTests {
    struct Checkout {
        let directory: URL
        let file: String
        let source: Int
        let answer: String
    }
}
