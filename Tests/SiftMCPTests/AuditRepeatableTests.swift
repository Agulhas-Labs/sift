//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Covers an audit giving the same inputs the same output: one run reads the machine's indexes once, and nothing it prints depends on a dictionary's order.
@Suite(.temporaryDirectories)
struct AuditRepeatableTests {
    /// A store deleted part way through a run never turns a declared name into one no index declares: the run still asks the connection it opened, and a question that connection can no longer read errs toward advising, as a missing store does.
    @Test
    func aStoreThatGoesMidRunIsStillTheStoreTheRunJudgesAgainst() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        try await SiftEngine(directory: root, registry: registry).ensureFresh()
        let run = AdvisableName.memoised(in: RunIndexState(registry: registry.currentRoots))

        #expect(!run("QzxNeverDeclared", root.path))

        Self.removeStore(of: root)
        // The store really is gone for anyone asking now: with nothing to consult, the name stays advisable.
        #expect(AdvisableName.couldAnswer("QzxAlsoNeverDeclared", from: root.path, siblingRoots: []))
        #expect(AdvisableName.memoised(in: RunIndexState(registry: registry.currentRoots))("QzxAlsoNeverDeclared", root.path))

        #expect(!run("QzxNeverDeclared", root.path))
        #expect(run("Alpha", root.path))
    }

    /// A store dropped and rebuilt in place part way through a run, as a newer build rebuilds one at a new schema version, is still the store the rest of the run judges against, for names it declares and names it does not.
    @Test
    func aStoreRebuiltInPlaceMidRunIsStillTheStoreTheRunJudgesAgainst() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        try await SiftEngine(directory: root, registry: registry).ensureFresh()
        let run = AdvisableName.memoised(in: RunIndexState(registry: registry.currentRoots))

        #expect(!run("QzxNeverDeclared", root.path))

        let writer = try SQLiteDatabase(path: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path)
        for statement in IndexSchema.dropStatements {
            try writer.execute(statement)
        }
        // The store really is emptied for anyone asking now: with no build to consult, the name stays advisable.
        #expect(AdvisableName.memoised(in: RunIndexState(registry: registry.currentRoots))("QzxAlsoNeverDeclared", root.path))

        #expect(!run("QzxAlsoNeverDeclared", root.path))
        #expect(run("Alpha", root.path))
    }

    /// The replay's hook judges a name against the store the audit's scan judged it against, so a store rebuilt between the two passes moves neither.
    @Test
    func theReplayJudgesANameAgainstTheStoreTheAuditDid() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        try await SiftEngine(directory: root, registry: registry).ensureFresh()
        let state = RunIndexState(registry: registry.currentRoots)
        defer { state.close() }
        // The run reads the store first, then another session's newer build drops and rebuilds it in place before the
        // replay asks about the name.
        #expect(AdvisableName.memoised(in: state)("Alpha", root.path))
        let writer = try SQLiteDatabase(path: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path)
        for statement in IndexSchema.dropStatements {
            try writer.execute(statement)
        }
        let hook = try HookReplay(
            directory: TemporaryDirectory.make("hook-replay"),
            timeBudget: InPlaceAnswerTests.roomy,
            couldAnswer: AdvisableName.memoised(in: state)
        )
        let directory = root.path

        let verdict = await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = [
                "tool_name": "Bash",
                "tool_input": ["command": "grep -rn QzxNeverDeclared Sources --include=*.swift"],
                "session_id": "replayed-session",
                "tool_use_id": "c1",
                "cwd": directory,
            ]
            return hook.verdict(payload: payload, cwd: directory, at: nil, decides: true)
        }

        // The audit's scan counts the name as one no index declares, and the replay's hook withholds it by the same rule.
        #expect(!AdvisableName.memoised(in: state)("QzxNeverDeclared", root.path))
        #expect(verdict?.rule == "unknownName (logged)", "\(String(describing: verdict))")
    }

    /// Where several in-place answers credit one file, a later read of it names the answer the transcript made first, in every file of the transcript, never the one a dictionary happened to yield.
    @Test
    func aFileTwoAnswersCreditedNamesTheEarlierAsItsLocator() throws {
        let files = (0 ..< 10).map { "Depot\($0)" }
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("answered-session.jsonl")
        var lines: [Data] = []
        let rerun = " instead of running it — re-run the identical command if you wanted its raw output."
        for name in files {
            let file = "Sources/\(name).swift"
            lines += [
                TranscriptFixture.toolUse("Bash", id: "\(name)-window", input: ["command": "sed -n '1,5p' \(file)"], cwd: "/nowhere"),
                TranscriptFixture.toolResult(
                    id: "\(name)-window",
                    isError: true,
                    text: "PreToolUse:Bash hook error: sift answered this with `digest \(file)` (only the members of lines 1-5 are shown; "
                        + "the whole digest is no smaller than the lines asked for)\(rerun)\n\n\(file) lines 1-5 overlap:\nstruct \(name)  :1-40",
                    bareText: true
                ),
                TranscriptFixture.toolUse("Bash", id: "\(name)-whole", input: ["command": "cat \(file)"], cwd: "/nowhere"),
                TranscriptFixture.toolResult(
                    id: "\(name)-whole",
                    isError: true,
                    text: "PreToolUse:Bash hook error: sift answered this with `digest \(file)`\(rerun)\n\n\(file) — module: App\nstruct \(name)  :1-40",
                    bareText: true
                ),
            ]
        }
        for name in files {
            lines += [
                TranscriptFixture.toolUse("Read", id: "\(name)-read", input: ["file_path": "/nowhere/Sources/\(name).swift", "offset": 10, "limit": 20]),
                TranscriptFixture.toolResult(id: "\(name)-read", isError: false, text: "struct \(name)"),
            ]
        }
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: transcript.deletingLastPathComponent(), since: nil, transcript: transcript.path)
        let windows = ScanDumpRequest(snapshot: snapshot, since: nil, until: nil, suppressionLog: nil).windows()

        for name in files {
            let read = try #require(windows.first { $0.call == "\(name)-read" }, "\(windows)")
            #expect(read.locator == LocatingCall(tool: "answer", call: "\(name)-window"), "\(name): \(read)")
        }
    }
}

private extension AuditRepeatableTests {
    /// Removes the index at `root` the way another session deleting it would: the store and its two companion files.
    static func removeStore(of root: URL) {
        let cache = SiftPaths.cache(in: root)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(SiftPaths.indexFileName + suffix))
        }
    }
}
