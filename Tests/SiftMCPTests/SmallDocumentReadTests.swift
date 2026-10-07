//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a Markdown document of at most 8 KiB is let through and logged as `smallDocument`; a larger one, and a Swift file of any size, is judged as before.
@Suite(.temporaryDirectories)
struct SmallDocumentReadTests {
    /// A whole `Read` of `path`, as the harness hands it to the hook.
    private static func read(_ path: String, in root: URL) -> [String: Any] {
        ["tool_name": "Read", "tool_input": ["file_path": path], "cwd": root.path]
    }

    /// The hook's lookup for a whole read of `path`, and the suppression log it wrote.
    private static func lookup(_ path: String, in root: URL) throws -> (lookup: PreToolUseCommand.Lookup?, logged: String) {
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        let lookup = PreToolUseCommand.lookup(command: nil, payload: read(path, in: root), in: root.path, noting: SuppressionLog(fileURL: log))
        return (lookup, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    /// Writes `head`, `filler` lines, a `//` pad line and `tail` to exactly `bytes` bytes at `relative` under `root`, well past the 60-line floor.
    private static func write(_ head: String, filler: (Int) -> String, tail: String = "", bytes: Int, at relative: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        var content = head
        var index = 1
        while content.utf8.count + filler(index).utf8.count + 1 + 4 + tail.utf8.count < bytes {
            content += filler(index) + "\n"
            index += 1
        }
        content += "//" + String(repeating: "x", count: bytes - content.utf8.count - 3 - tail.utf8.count) + "\n" + tail
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: url).count == bytes, sourceLocation: sourceLocation)
        return url
    }

    /// A Markdown document of `bytes` bytes, in sections of prose.
    private static func document(bytes: Int, in root: URL) throws -> URL {
        try write("# Notes\n\n", filler: { index in
            index.isMultiple(of: 12) ? "## Section \(index / 12)\n" : "Line \(index) of a note, written at a length a real one runs to."
        }, bytes: bytes, at: "Docs/Notes.md", in: root)
    }

    /// A Swift file of `bytes` bytes, a type of many small members.
    private static func source(bytes: Int, in root: URL) throws -> URL {
        try write("/// A ledger.\nstruct Ledger {\n", filler: { index in
            "    func entry\(index)() -> Int { \(index) * 2 }"
        }, tail: "}\n", bytes: bytes, at: "Sources/App/Ledger.swift", in: root)
    }

    @Test
    func aDocumentOfEightKiBIsLetThroughAndLogged() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let document = try Self.document(bytes: 8192, in: root)

        let judged = try Self.lookup(document.path, in: root)

        #expect(judged.lookup == nil)
        #expect(judged.logged.contains("\"smallDocument\""), "\(judged.logged)")
    }

    @Test
    func aDocumentOneBytePastIsStillAdvised() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let document = try Self.document(bytes: 8193, in: root)

        let judged = try Self.lookup(document.path, in: root)

        #expect(judged.lookup?.rule == "ReadAdvice")
        #expect(judged.lookup?.inPlace != nil)
        #expect(!judged.logged.contains("smallDocument"), "\(judged.logged)")
    }

    /// A document under the 60-line floor is excused by the floor, as it always was, and so is not logged as small.
    @Test
    func aDocumentBelowTheFloorIsNotLoggedAsSmall() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let short = root.appendingPathComponent("Docs/Short.md")
        try FileManager.default.createDirectory(at: short.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Short\n\nA line.\n".write(to: short, atomically: true, encoding: .utf8)

        let judged = try Self.lookup(short.path, in: root)

        #expect(judged.lookup == nil)
        #expect(!judged.logged.contains("smallDocument"), "\(judged.logged)")
    }

    @Test
    func aSwiftFileOfTheSameSizeIsUnchanged() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let source = try Self.source(bytes: 8192, in: root)

        let judged = try Self.lookup(source.path, in: root)

        #expect(judged.lookup?.rule == "ReadAdvice")
        #expect(judged.lookup?.suggestion.call == "digest Ledger")
        #expect(!judged.logged.contains("smallDocument"), "\(judged.logged)")
    }
}
