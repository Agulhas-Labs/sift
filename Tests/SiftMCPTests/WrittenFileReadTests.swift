//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A read of a file this context wrote or edited is a revisit: the write put the file's text in the context, so the hook lets the read through and the scan files it revisited rather than cold.
@Suite(.temporaryDirectories)
struct WrittenFileReadTests {
    /// The measured case: a file written, then a ranged read of it to edit a test, which the hook answered with the file's digest.
    @Test func aRangedReadOfAWrittenFileIsLetThrough() throws {
        let fixture = try Fixture()
        #expect(try fixture.verdict(fixture.rangedRead(), session: "s0").token == "in-place")

        fixture.write(tool: "Write", path: fixture.file)

        #expect(try fixture.verdict(fixture.rangedRead()).line == "allowed\t\twritten")
    }

    /// An edit holds the file the same way, for a ranged read and a whole one alike.
    @Test func aReadOfAnEditedFileIsLetThrough() throws {
        let fixture = try Fixture()
        fixture.write(tool: "Edit", path: fixture.file)

        #expect(try fixture.verdict(fixture.rangedRead()).line == "allowed\t\twritten")
        #expect(try fixture.verdict(fixture.wholeRead()).line == "allowed\t\twritten")
    }

    /// Another session never held the file, and a write of another file says nothing about this one, so both reads are still answered.
    @Test func aWriteElsewhereLeavesTheReadAnswered() throws {
        let fixture = try Fixture()
        fixture.write(tool: "Write", path: fixture.file, session: "s2")
        fixture.write(tool: "Write", path: fixture.repo.appendingPathComponent("Sources/App/Other.swift").path)

        #expect(try fixture.verdict(fixture.rangedRead()).token == "in-place")
        #expect(try fixture.verdict(fixture.rangedRead(), session: "s2").line == "allowed\t\twritten")
    }

    /// The scan files the read after a write as a revisit, and a read of a file nobody wrote as cold.
    @Test func theScanFilesAReadAfterAWriteAsRevisited() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Write", id: "w1", input: ["file_path": "/repo/A.swift", "content": "struct A {}"]),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/A.swift", "offset": 149, "limit": 28]),
            TranscriptFixture.toolUse("Edit", id: "e1", input: ["file_path": "/repo/B.swift", "old_string": "a", "new_string": "b"]),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/B.swift"]),
            TranscriptFixture.toolUse("Read", id: "r3", input: ["file_path": "/repo/C.swift", "offset": 1, "limit": 20]),
        ], belowFloor: { _ in false })

        #expect(lookups == [.revisited(file: "/repo/A.swift"), .revisited(file: "/repo/B.swift"), .cold(file: "/repo/C.swift", missed: nil)])
    }

    /// The replay reads the same transcript the same way: the read after the write is no cold lookup to recover.
    @Test func theReplayCountsNoColdLookupForAReadAfterAWrite() async throws {
        let fixture = try Fixture()
        let stamp = "2026-09-24T10:00:00Z"
        let lines = try [
            Self.use("Write", input: ["file_path": fixture.file, "content": "struct Shell {}"], id: "w1", cwd: fixture.repo.path, at: stamp),
            TranscriptFixture.toolResult(id: "w1", isError: false, text: "written"),
            Self.use("Read", input: ["file_path": fixture.file, "offset": 1, "limit": 30], id: "r1", cwd: fixture.repo.path, at: stamp),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Shell"),
        ]
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let section = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.section(projectsDirectory: transcript.deletingLastPathComponent(), since: nil, transcript: transcript.path, hook: hook)
        }

        #expect(section.contains { $0.hasPrefix("  cold            0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  recovered       0  ") }, "\(section)")
    }

    /// The replayed hook notes a write as the live one does, so its verdict on the read that follows is the live one's.
    @Test func theReplayedHookLetsTheReadAfterAWriteThrough() throws {
        let fixture = try Fixture()
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let session: [String: Any] = ["session_id": "s1", "agent_id": "a1"]
        let write = session.merging(["tool_name": "Write", "tool_input": ["file_path": fixture.file, "content": "struct Shell {}"]]) { $1 }
        let read = session.merging(["tool_name": "Read", "tool_input": ["file_path": fixture.file, "offset": 1, "limit": 30]]) { $1 }

        #expect(hook.verdict(payload: write, cwd: fixture.repo.path, at: nil, decides: true) == nil)
        let verdict = hook.verdict(payload: read, cwd: fixture.repo.path, at: nil, decides: true)
        #expect(verdict?.token == "allowed")
        #expect(verdict?.rule == "written")
    }

    private static func use(_ tool: String, input: [String: Any], id: String, cwd: String, at stamp: String) throws -> Data {
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": cwd,
            "timestamp": stamp,
            "message": ["id": "m-\(id)", "content": [["type": "tool_use", "id": id, "name": tool, "input": input]]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension WrittenFileReadTests {
    /// A repository holding a `Shell.swift` long enough that its digest is worth answering with, and every store the hook writes, somewhere this test owns.
    struct Fixture {
        let repo: URL
        let stores: URL

        init() throws {
            repo = try MCPTestRepo.make(declaring: "Shell")
            stores = try TemporaryDirectory.make("written-stores")
            let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
            try ("/// The test type.\nstruct Shell {\n" + members.joined(separator: "\n") + "\n}\n")
                .write(to: repo.appendingPathComponent("Sources/App/Shell.swift"), atomically: true, encoding: .utf8)
        }

        var file: String {
            repo.appendingPathComponent("Sources/App/Shell.swift").path
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: stores.appendingPathComponent("advice"))
        }

        func context(_ session: String) -> AdviceContext {
            AdviceContext.resolve(sessionID: session, transcriptPath: nil, agentID: "a1")
        }

        /// The hook seeing a write or an edit of `path` in `session`.
        func write(tool: String, path: String, session: String = "s1", sourceLocation: SourceLocation = #_sourceLocation) {
            let payload: [String: Any] = ["tool_name": tool, "tool_input": ["file_path": path], "agent_id": "a1"]
            #expect(PreToolUseCommand.notesWrite(context: context(session), payload: payload, cwd: repo.path, ledger: ledger), sourceLocation: sourceLocation)
        }

        func rangedRead(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try read(["file_path": file, "offset": 149, "limit": 28], sourceLocation: sourceLocation)
        }

        func wholeRead(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try read(["file_path": file], sourceLocation: sourceLocation)
        }

        private func read(_ input: [String: Any], sourceLocation: SourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(PreToolUseCommand.lookup(
                command: nil,
                payload: ["tool_name": "Read", "tool_input": input],
                in: repo.path,
                noting: SuppressionLog(fileURL: stores.appendingPathComponent("suppressions.jsonl")),
                couldAnswer: { _, _ in true }
            ), sourceLocation: sourceLocation)
        }

        /// The hook's decision on `lookup`, with an answerer that always answers in place.
        func verdict(_ lookup: PreToolUseCommand.Lookup, session: String = "s1") -> PreToolUseCommand.Verdict {
            let answered = InPlaceAnswerer.Answered(
                reason: "answered",
                calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Shell.swift", bytes: AnswerBytes(served: 1, source: 2))],
                root: repo.path,
                milliseconds: 1
            )
            return PreToolUseCommand.outcome(
                to: lookup,
                session: session,
                context: context(session),
                payload: ["agent_id": "a1"],
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: stores.appendingPathComponent("usage.jsonl")),
                suppressions: SuppressionLog(fileURL: stores.appendingPathComponent("suppressions.jsonl")),
                answerer: { _, _, _ in .answered(answered) }
            ).verdict
        }
    }
}
