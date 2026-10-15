//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A batched read whose note leaves a file out because the context already holds its digest keeps that file's read on the suggested line: the digest of the rest does not replace it.
@Suite(.temporaryDirectories)
struct BatchedNoteKeepsHeldTests {
    /// `CatSeveralFilesVerdictTests`' repository with a third file whose digest is worth the turn, `Third`.
    static func repository() async throws -> URL {
        let root = try await CatSeveralFilesVerdictTests.repository()
        let body = (1 ... 20).map { "        let value\($0) = count * \($0) + offset" }.joined(separator: "\n")
        let functions = (1 ... 30).map { "    func step\($0)(count: Int, offset: Int) -> Int {\n\(body)\n        return count\n    }" }
        try ("/// A Third.\nstruct Third {\n" + functions.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Third.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The hook's output for `command` in a context that already holds the digests of `held`, answered by the real answerer against `root`.
    static func decide(_ command: String, holding held: [String], in root: URL) async throws -> String? {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        return await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_held"]
            let context = AdviceContext.resolve(sessionID: "s1", transcriptPath: nil)
            let ledger = AdviceLedger(directory: advice)
            ledger.noteIndexCall(session: context.key, calls: held.map { "digest \($0)" }, digests: [root.path: held])
            guard let lookup = PreToolUseCommand.lookup(
                command: command,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: log),
                couldAnswer: { _, _ in true }
            ) else {
                return nil
            }
            return PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: context,
                payload: payload,
                command: command,
                cwd: root.path,
                ledger: ledger,
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: log),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) },
                serverPresence: { _, _ in false }
            ).json
        }
    }

    /// With the first file's digest held, the note digests the other two and keeps the first file's read on the line.
    @Test func aHeldFileKeepsItsReadOnTheSuggestedLine() async throws {
        let root = try await Self.repository()

        let json = try await Self.decide(
            "cat Sources/App/Large.swift Sources/App/Other.swift Sources/App/Third.swift",
            holding: ["Sources/App/Large.swift"],
            in: root
        )

        let note = try #require(BatchedReadNoteTests.specific(json)?["additionalContext"] as? String, "\(json ?? "nil")")

        #expect(note.contains("`sift digest Sources/App/Other.swift`"), "\(note)")
        #expect(note.contains("`sift digest Sources/App/Third.swift`"), "\(note)")
        #expect(!note.contains("sift digest Sources/App/Large.swift"), "\(note)")
        #expect(note.hasSuffix("in place of the read, keeping its own read of `Sources/App/Large.swift`, which this context already holds."), "\(note)")
    }

    /// With every digest held there is nothing to answer: the line is let through with no note, not offered an empty call.
    @Test func everyDigestHeldIsLetThroughWithNoNote() async throws {
        let root = try await Self.repository()

        let json = try await Self.decide(
            "cat Sources/App/Large.swift Sources/App/Other.swift",
            holding: ["Sources/App/Large.swift", "Sources/App/Other.swift"],
            in: root
        )

        #expect(json == nil, "\(json ?? "nil")")
    }
}
