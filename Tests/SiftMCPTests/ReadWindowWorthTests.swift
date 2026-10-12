//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A narrower window a `Read` asked for is answered only where its answer spares more than the identical re-run is expected to cost: the window's own tokens and a turn, in ``WholeReadWorth/readWindowReRunShare`` of cases.
///
/// A `sed -n` window over the same lines keeps the window rules alone, and a `Read` window printing most of the file keeps the whole-read rule.
@Suite(.temporaryDirectories)
struct ReadWindowWorthTests {
    // MARK: - The inequality

    /// At the default context a turn is 720 tokens, so a window of 2,000 tokens is worth answering only with an answer under 2,777.6 bytes: `2000 − D/4 > 0.48 · (2000 + 720)`.
    @Test(arguments: [(2700, true), (2777, true), (2778, false), (2800, false)])
    func theDefaultContextBoundary(answerBytes: Int, worth: Bool) {
        #expect(WholeReadWorth.isReadWindowWorthTheTurn(windowBytes: 8000, answerBytes: answerBytes, contextTokens: nil) == worth)
    }

    /// A larger context makes the re-run's turn dearer, so the same window and answer worth answering at 20,000 tokens are let through at 120,000.
    @Test
    func aLargerContextLetsTheSameWindowThrough() {
        #expect(WholeReadWorth.isReadWindowWorthTheTurn(windowBytes: 8000, answerBytes: 3000, contextTokens: 20000))
        #expect(!WholeReadWorth.isReadWindowWorthTheTurn(windowBytes: 8000, answerBytes: 3000, contextTokens: 120_000))
    }

    // MARK: - Through the hook, with a stubbed answer

    /// A file of exactly 100 lines on disk, so the share a window prints is its line count in hundredths.
    private static func hundredLineFile() throws -> URL {
        let directory = try TemporaryDirectory.make("read-window-worth")
        let file = directory.appendingPathComponent("Depot.swift")
        try ((1 ... 100).map { "// line \($0)" }.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A `Read` of `file` from `offset` for `limit` lines.
    private static func read(_ file: URL, offset: Int, limit: Int) -> [String: Any] {
        ["tool_name": "Read", "tool_input": ["file_path": file.path, "offset": offset, "limit": limit], "session_id": "s1", "tool_use_id": "toolu_read_window"]
    }

    private static func bash(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_read_window"]
    }

    /// The hook's printed decision and verdict for `payload`, every lookup answered with a digest of `served` bytes standing in for `source`.
    private static func judged(_ payload: [String: Any], in directory: URL, answers served: Int, of source: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        let scratch = try TemporaryDirectory.make("read-window-worth-hook")
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
        let lookup = try #require(PreToolUseCommand.lookup(command: command, payload: payload, in: directory.path, noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        let target = directory.appendingPathComponent("Depot.swift").path
        let reason = "sift answered this with `digest \(target)` instead of running it\(InPlaceAnswer.openingSuffix)\n\nbody"
        let call = InPlaceAnswerer.Call(tool: "digest", target: target, bytes: AnswerBytes(served: served, source: source), intercepted: .window)
        let answered = InPlaceAnswerer.Outcome.answered(InPlaceAnswerer.Answered(reason: reason, calls: [call], root: directory.path, milliseconds: 1, wholeRead: call.bytes))
        return PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
            payload: payload,
            command: command,
            cwd: directory.path,
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions,
            answerer: { _, _, _ in answered }
        )
    }

    /// A `Read` window whose answer spares less than its expected re-run is let through, logged as `notWorthTheTurn`.
    @Test
    func aReadWindowSparingLessThanItsReRunIsLetThrough() throws {
        let file = try Self.hundredLineFile()

        let judged = try Self.judged(Self.read(file, offset: 1, limit: 40), in: file.deletingLastPathComponent(), answers: 2800, of: 8000)

        #expect(judged.verdict.token == "allowed" && judged.verdict.rule == "notWorthTheTurn", "\(judged.verdict.line)")
        #expect(judged.json == nil)
    }

    /// A `Read` window whose answer spares more than its expected re-run is still answered.
    @Test
    func aReadWindowSparingMoreThanItsReRunIsAnswered() throws {
        let file = try Self.hundredLineFile()

        let judged = try Self.judged(Self.read(file, offset: 1, limit: 40), in: file.deletingLastPathComponent(), answers: 2700, of: 8000)

        #expect(judged.verdict.token == "in-place", "\(judged.verdict.line)")
        #expect(judged.json?.contains("sift answered this with") == true)
    }

    /// The same lines asked for with `sed -n`, and the same answer, are answered as they always were.
    @Test
    func aSedWindowOfTheSameLinesIsStillAnswered() throws {
        let file = try Self.hundredLineFile()

        let judged = try Self.judged(Self.bash("sed -n 1,40p Depot.swift"), in: file.deletingLastPathComponent(), answers: 2800, of: 8000)

        #expect(judged.verdict.token == "in-place", "\(judged.verdict.line)")
        #expect(judged.json?.contains("sift answered this with") == true)
    }

    /// A `Read` window printing most of the file is weighed as the whole read is: an answer the window rule would keep is let through where the whole read's digest spares less than its turn.
    @Test
    func aReadWindowOverMostOfTheFileKeepsTheWholeReadRule() throws {
        let file = try Self.hundredLineFile()
        #expect(WholeReadWorth.isReadWindowWorthTheTurn(windowBytes: 8000, answerBytes: 1000, contextTokens: nil))
        #expect(!WholeReadWorth.isWorthTheTurn(fileBytes: 8000, digestBytes: 1000, contextTokens: nil))

        let judged = try Self.judged(Self.read(file, offset: 1, limit: 80), in: file.deletingLastPathComponent(), answers: 1000, of: 8000)

        #expect(judged.verdict.token == "allowed" && judged.verdict.rule == "notWorthTheTurn", "\(judged.verdict.line)")
    }

    // MARK: - Through the real answerer

    /// The hook's verdict line for `payload`, answered by the real answerer against `root`.
    private static func decide(_ made: @escaping @Sendable () -> [String: Any], in root: URL) async throws -> String {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        return await InPlaceAnswerTests.onItsOwnThread { () -> String in
            let payload = made()
            let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
            guard let lookup = PreToolUseCommand.lookup(command: command, payload: payload, in: root.path, noting: SuppressionLog(fileURL: log), couldAnswer: { _, _ in true }) else {
                return "no lookup"
            }
            return PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                command: command,
                cwd: root.path,
                ledger: AdviceLedger(directory: advice),
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: log),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) },
                serverPresence: { _, _ in false }
            ).verdict.line
        }
    }

    /// `payload` as a replay hands it over, in a context of `tokens`.
    private static func inContext(_ tokens: Int, _ payload: [String: Any]) -> [String: Any] {
        var payload = payload
        payload[ContextSize.replayKey] = tokens
        return payload
    }

    /// Half of `Depot`'s lines, twenty of its forty padded members: answered at the default context, let through at 200,000 tokens, where the re-run's turn outweighs what the answer spares.
    @Test(arguments: [(nil, "in-place"), (200_000, "allowed\t\tnotWorthTheTurn")] as [(Int?, String)])
    func aRealReadWindowIsWeighedByItsContext(tokens: Int?, verdict expected: String) async throws {
        let root = try await WorthAnsweringFixture.repository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")

        let verdict = try await Self.decide({ tokens.map { Self.inContext($0, Self.read(file, offset: 3, limit: 100)) } ?? Self.read(file, offset: 3, limit: 100) }, in: root)

        #expect(expected == "in-place" ? verdict.hasPrefix("in-place") : verdict == expected, "\(verdict)")
    }

    /// The same lines through `sed -n`, in the same large context, are answered.
    @Test
    func aRealSedWindowInALargeContextIsAnswered() async throws {
        let root = try await WorthAnsweringFixture.repository()

        let verdict = try await Self.decide({ Self.inContext(200_000, Self.bash("sed -n 3,102p Sources/App/Depot.swift")) }, in: root)

        #expect(verdict.hasPrefix("in-place"), "\(verdict)")
    }
}
