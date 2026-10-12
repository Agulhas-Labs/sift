//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// An overrun during a cold start arms a short back-off rather than the full window, a warm one still arms the full window, and the hook's `overTime` row names the shapes that ran out of time.
@Suite(.temporaryDirectories)
struct BackoffColdStartTests {
    /// A deadline already past whenever it is asked, so every answer that reaches the wait overruns.
    private static let alreadyPast = InPlaceDeadline { _ in .now() }

    /// A repository no index has ever been built in: what a fresh machine's first session finds.
    private static func coldRepository() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try "struct Depot {\n    func stock() -> Int {\n        1\n    }\n}\n"
            .write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// `call` answered from `root` on a thread of its own, held to `deadline`, against `backoff`.
    private static func answer(_ call: InPlaceCall, in root: URL, deadline: InPlaceDeadline = .wallClock, backoff: InPlaceBackoff) async -> InPlaceAnswerer.Outcome {
        await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(call, from: root.path, timeBudget: InPlaceAnswerTests.roomy, deadline: deadline, backoff: backoff)
        }
    }

    /// A first lookup that overruns while the index is still to be built holds its shape off for the short window, exactly ``InPlaceBackoff/coldStartWindow``, rather than the full one: a lookup right after the overrun and one a second before the window ends are held off, and one at the window's end is tried again.
    @Test
    func aColdStartOverrunArmsOnlyAShortBackoff() async throws {
        let root = try Self.coldRepository()
        let clock = Clock()
        let backoff = try InPlaceBackoff(directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"), now: { clock.now })
        let digest = InPlaceCall.fileDigest(path: "Sources/App/Depot.swift")

        #expect(!ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        #expect(await Self.answer(digest, in: root, deadline: Self.alreadyPast, backoff: backoff) == .withheld(.overTime))
        clock.advance(by: 1)
        #expect(await Self.answer(digest, in: root, backoff: backoff) == .withheld(.backingOff))
        // One second has passed: the short window holds to its last second and lets go at exactly its length.
        clock.advance(by: InPlaceBackoff.coldStartWindow - 2)
        #expect(await Self.answer(digest, in: root, backoff: backoff) == .withheld(.backingOff))
        clock.advance(by: 1)
        #expect(await Self.answer(digest, in: root, backoff: backoff) != .withheld(.backingOff))
    }

    /// An overrun where the index is built is the full window's business: the shape is held off up to the window's last second and tried again after it.
    @Test
    func aWarmOverrunStillArmsTheFullWindow() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let clock = Clock()
        let backoff = try InPlaceBackoff(directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"), now: { clock.now })
        let digest = InPlaceCall.fileDigest(path: "Sources/App/Depot.swift")

        #expect(ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        #expect(await Self.answer(digest, in: root, deadline: Self.alreadyPast, backoff: backoff) == .withheld(.overTime))
        clock.advance(by: InPlaceBackoff.window - 1)
        #expect(await Self.answer(digest, in: root, backoff: backoff) == .withheld(.backingOff))
        clock.advance(by: 2)
        guard case .answered = await Self.answer(digest, in: root, backoff: backoff) else {
            Issue.record("expected the read answered once the window passed")
            return
        }
    }

    /// The `overTime` row a whole read leaves names the read shape and the full window it armed; one an answerer reports without any answer running out of time names no shape and no back-off.
    @Test
    func anOverTimeRowNamesTheShapeThatRanOut() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift").path
        let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file], "session_id": "s1", "tool_use_id": "toolu_read"]
        let backoff = try InPlaceAnswerTests.backoff()

        let row = try await Self.row(for: payload, command: nil, in: root) { match, gone in
            InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, deadline: Self.alreadyPast, backoff: backoff)
        }
        #expect(row["symbol"] as? String == "overTime")
        #expect(row["shapes"] as? [String] == ["read"])
        #expect(row["backoff"] as? Int == 300)

        let unrun: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file], "session_id": "s2", "tool_use_id": "toolu_unrun"]
        let bare = try await Self.row(for: unrun, command: nil, in: root) { _, _ in .withheld(.overTime) }
        #expect(bare["symbol"] as? String == "overTime")
        #expect(bare["shapes"] as? [String] == [])
        #expect(bare["backoff"] == nil)
    }

    /// A word-anchored sweep whose proof fails falls back to the names shape; where that fallback is what runs out of time, the row names the names shape, not the sweep the command was read as.
    @Test
    func aFallbackOverrunNamesTheShapeThatActuallyRanOut() async throws {
        let root = try await EngineReuseTests.builtPackage()
        try MCPTestRepo.add(["Sources/App/Notes.swift": "// Depot is built once per session\nstruct Notes {}\n"], to: root)
        let command = "grep -rnw Depot Sources"
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_sweep"]
        let backoff = try InPlaceAnswerTests.backoff()
        // The anchored reading is given all the time it needs, so its proof fails rather than its clock; the fallback is out of time.
        let asked = Counter()
        let fallbackOutOfTime = InPlaceDeadline { _ in asked.next() == 1 ? .distantFuture : .now() }

        let row = try await Self.row(for: payload, command: command, in: root) { match, gone in
            InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, deadline: fallbackOutOfTime, backoff: backoff)
        }

        #expect(asked.count == 2)
        #expect(row["symbol"] as? String == "overTime")
        #expect(row["shapes"] as? [String] == ["symbols"])
    }

    /// The suppression row the hook writes for one call, answered by `answerer` on a thread of its own.
    private static func row(
        for payload: [String: Any],
        command: String?,
        in root: URL,
        answerer: @escaping @Sendable (InPlaceShape.Match, Bool) -> InPlaceAnswerer.Outcome,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [String: Any] {
        let directory = try TemporaryDirectory.make("hook").appendingPathComponent("hook")
        let ledger = AdviceLedger(directory: directory.appendingPathComponent("advice"))
        let (suppressionLog, usageLog) = (directory.appendingPathComponent("suppressions.jsonl"), directory.appendingPathComponent("usage.jsonl"))
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        await InPlaceAnswerTests.onItsOwnThread {
            guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let lookup = PreToolUseCommand.lookup(
                      command: command,
                      payload: payload,
                      in: root.path,
                      noting: SuppressionLog(fileURL: suppressionLog),
                      couldAnswer: { _, _ in true }
                  )
            else { return }
            _ = PreToolUseCommand.respond(
                to: lookup,
                session: payload["session_id"] as? String,
                context: AdviceContext.resolve(sessionID: payload["session_id"] as? String ?? "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: ledger,
                usage: UsageLog(fileURL: usageLog),
                suppressions: SuppressionLog(fileURL: suppressionLog),
                answerer: { match, gone, _ in answerer(match, gone) }
            )
        }
        let id = payload["tool_use_id"] as? String
        let text = (try? String(contentsOf: suppressionLog, encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return try #require(rows.last { $0["call"] as? String == id }, sourceLocation: sourceLocation)
    }
}

private extension BackoffColdStartTests {
    /// How many times a deadline was asked for, counting from one.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0

        var count: Int {
            lock.withLock { asked }
        }

        func next() -> Int {
            lock.withLock {
                asked += 1
                return asked
            }
        }
    }

    /// A clock a test moves by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()

        var now: Date {
            lock.withLock { current }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(interval) }
        }
    }
}
