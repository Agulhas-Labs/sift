//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A shell line that prints a digested file whole is the read the digest existed to save, as a whole `Read` of it is: read whole after its digest in the share, and counted among the whole reads every face states beside its gross saving.
@Suite(.temporaryDirectories)
struct ShellReadAfterDigestTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    /// A checkout holding one file well above the digest floor, and the digest answer the index would serve for it.
    private static func checkout() throws -> Checkout {
        let directory = try TemporaryDirectory.make("shell-read-after-digest")
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

    private static func tally(_ lines: [Data], checkout: Checkout) throws -> TranscriptTally {
        let transcript = checkout.directory.appendingPathComponent("session.jsonl")
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        let usageLog = checkout.directory.appendingPathComponent("usage.jsonl")
        let usage = usageLine(served: checkout.answer.utf8.count, source: checkout.source)
        try (usage + "\n").write(to: usageLog, atomically: true, encoding: .utf8)
        return TranscriptFixture.scored(transcript: transcript)
    }

    private static func mcpDigest(answer: String, cwd: String) -> [Data] {
        [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: cwd),
            TranscriptFixture.indexAnswer(id: "d1", text: answer),
        ]
    }

    private static func shell(_ command: String, id: String, cwd: String) -> [Data] {
        [
            TranscriptFixture.toolUse("Bash", id: id, input: ["command": command], cwd: cwd),
            TranscriptFixture.toolResult(id: id, isError: false, text: "public struct Depot {"),
        ]
    }

    /// Every shell spelling of a whole read the hook treats as a Swift lookup, relative, behind a `cd`, or alongside another file.
    ///
    /// An `nl -ba` standing alone is no lookup at all (``NumberedRead``), so it is not among them.
    @Test(arguments: [
        "cat Sources/App/Depot.swift",
        "cat -n Sources/App/Depot.swift",
        "awk '{print}' Sources/App/Depot.swift",
        "cd Sources/App && cat Depot.swift",
        "cat Package.swift Sources/App/Depot.swift",
    ])
    func aShellWholeReadAfterAnMCPDigestSavesNothing(command: String) throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path
        let lines = Self.mcpDigest(answer: checkout.answer, cwd: cwd) + Self.shell(command, id: "b1", cwd: cwd)

        let tally = try Self.tally(lines, checkout: checkout)

        #expect(tally.readWholeAfterDigest == 1)
        #expect(tally.cold == 0)
    }

    /// The same after a digest the CLI served from a Bash line.
    @Test
    func aShellWholeReadAfterACLIDigestSavesNothing() throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path
        let lines = Self.shell("sift digest \(Self.relative)", id: "c1", cwd: cwd).dropLast()
            + [TranscriptFixture.toolResult(id: "c1", isError: false, text: checkout.answer)]
            + Self.shell("cat \(checkout.file)", id: "b1", cwd: cwd)

        let tally = try Self.tally(Array(lines), checkout: checkout)

        #expect(tally.readWholeAfterDigest == 1)
    }

    /// A shell window the digest located is the loop working: guided, and the saving kept.
    @Test
    func aShellWindowAfterADigestKeepsTheSaving() throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path
        let lines = Self.mcpDigest(answer: checkout.answer, cwd: cwd) + Self.shell("sed -n '10,30p' \(Self.relative)", id: "b1", cwd: cwd)

        let tally = try Self.tally(lines, checkout: checkout)

        #expect(tally.readWholeAfterDigest == 0)
    }

    /// A whole read of a file no digest touched is the cold lookup it always was.
    @Test
    func aShellWholeReadWithNoDigestStaysCold() throws {
        let checkout = try Self.checkout()
        let cwd = checkout.directory.path

        let tally = try Self.tally(Self.shell("cat \(Self.relative)", id: "b1", cwd: cwd), checkout: checkout)

        #expect(tally.readWholeAfterDigest == 0)
        #expect(tally.cold == 1)
    }
}

private extension ShellReadAfterDigestTests {
    struct Checkout {
        let directory: URL
        let file: String
        let source: Int
        let answer: String
    }
}
