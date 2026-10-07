//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a Swift file is answered with its digest only where the digest spares more than the turn after it costs; otherwise the read runs, logged as `notWorthTheTurn`, and prints nothing to record.
@Suite(.temporaryDirectories)
struct NotWorthTheTurnTests {
    // MARK: - The inequality

    /// The file sizes, in bytes, at which a digest a fifth of the file turns worth answering with, for a context of 20k, 45k and 120k tokens: the margin crosses zero between each pair.
    @Test(arguments: [(20000, 5000, 5500), (45000, 8000, 8400), (120_000, 16000, 18000)])
    func theBoundaryMovesWithTheContext(context: Int, below: Int, above: Int) {
        #expect(!WholeReadWorth.isWorthTheTurn(fileBytes: below, digestBytes: below / 5, contextTokens: context))
        #expect(WholeReadWorth.isWorthTheTurn(fileBytes: above, digestBytes: above / 5, contextTokens: context))
    }

    /// At 45k and a digest a fifth of the file the margin is about 940 tokens before the file's own saving, so a file of 2k tokens is the break-even.
    @Test
    func theMarginAtTheMedianContextIsAboutNineHundredAndFortyTokens() {
        let file = 8000
        let spared = (1 - WholeReadWorth.wholeReReadShare) * Double(file) / 4 - Double(file / 5) / 4
        let margin = WholeReadWorth.margin(fileBytes: file, digestBytes: file / 5, contextTokens: 45000)

        #expect(abs((spared - margin) - 941) < 1, "\(spared - margin)")
    }

    /// An unknown context is the default one, and a bigger digest never helps.
    @Test
    func anUnknownContextIsTheDefaultAndABiggerDigestIsWorse() {
        #expect(WholeReadWorth.margin(fileBytes: 9000, digestBytes: 1800, contextTokens: nil) == WholeReadWorth.margin(fileBytes: 9000, digestBytes: 1800, contextTokens: ContextSize.defaultTokens))
        #expect(WholeReadWorth.margin(fileBytes: 9000, digestBytes: 3600, contextTokens: nil) < WholeReadWorth.margin(fileBytes: 9000, digestBytes: 1800, contextTokens: nil))
    }

    // MARK: - The context's size

    /// One transcript line for an assistant message that ran in `input` + `read` + `created` tokens.
    private static func assistant(input: Int, read: Int, created: Int, padding: Int = 0) -> String {
        let text = String(repeating: "x", count: padding)
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(created),"output_tokens":9}}}"#
    }

    private static func write(_ lines: [String], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The size is the last assistant message's three input counts summed, read from the end of a transcript far larger than the window read.
    @Test
    func theSizeIsTheLastAssistantUsageReadFromTheTail() throws {
        let directory = try TemporaryDirectory.make("context-size")
        let transcript = directory.appendingPathComponent("s1.jsonl")
        let filler = (0 ..< 40).map { _ in Self.assistant(input: 1, read: 2, created: 3, padding: 100_000) }
        try Self.write([Self.assistant(input: 1, read: 111, created: 1)] + filler + [Self.assistant(input: 2, read: 30000, created: 500), #"{"type":"user","message":{"content":"next"}}"#], to: transcript)

        #expect(ContextSize.latest(inTranscript: transcript.path) == 30502)
    }

    /// One assistant message larger than the first window is still found, by the wider one; a transcript holding none is unknown.
    @Test
    func aMessageLargerThanTheFirstWindowIsFoundAndNoMessageIsUnknown() throws {
        let directory = try TemporaryDirectory.make("context-size-wide")
        let wide = directory.appendingPathComponent("wide.jsonl")
        try Self.write([Self.assistant(input: 5, read: 7000, created: 0, padding: 200_000)], to: wide)
        let none = directory.appendingPathComponent("none.jsonl")
        try Self.write([#"{"type":"user","message":{"content":"hello"}}"#], to: none)

        #expect(ContextSize.latest(inTranscript: wide.path) == 7005)
        #expect(ContextSize.latest(inTranscript: none.path) == nil)
        #expect(ContextSize.latest(inTranscript: directory.appendingPathComponent("missing.jsonl").path) == nil)
    }

    /// A subagent's context is its own transcript under the session's `subagents/`, not the session's, and where that file is absent the default stands rather than the parent's usage.
    @Test
    func aSubagentsSizeIsReadFromItsOwnTranscriptAndNeverTheParents() throws {
        let directory = try TemporaryDirectory.make("context-size-agent")
        let session = directory.appendingPathComponent("s1.jsonl")
        try Self.write([Self.assistant(input: 1, read: 119_999, created: 0)], to: session)
        try Self.write([Self.assistant(input: 1, read: 19999, created: 0)], to: directory.appendingPathComponent("s1/subagents/agent-a1.jsonl"))
        let payload = { (agent: String?) -> [String: Any] in
            var payload: [String: Any] = ["transcript_path": session.path]
            payload["agent_id"] = agent
            return payload
        }

        #expect(ContextSize.ofCall(payload(nil)) == 120_000)
        #expect(ContextSize.ofCall(payload("a1")) == 20000)
        #expect(ContextSize.ofCall(payload("gone")) == ContextSize.defaultTokens)
        #expect(ContextSize.ofCall([:]) == ContextSize.defaultTokens)
    }

    /// A replay hands the hook the size as of the call, and none yet is the default.
    @Test
    func aReplayedCallCarriesTheSizeItFollowed() {
        let block: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/repo/A.swift"]]
        let identity = ReplayIdentity(sessionTranscript: "/transcripts/s1.jsonl", fallbackSession: "s1", fallbackAgent: nil)
        let followed = ReplayCall(block: block, line: ["sessionId": "s1"], identity: identity, origins: WorktreeOrigins(), contextTokens: 77000)
        let first = ReplayCall(block: block, line: ["sessionId": "s1"], identity: identity, origins: WorktreeOrigins())

        #expect(ContextSize.ofCall(followed.payload) == 77000)
        #expect(ContextSize.ofCall(first.payload) == ContextSize.defaultTokens)
    }

    // MARK: - The hook

    private static var file: String {
        "/repo/Sources/App/Depot.swift"
    }

    /// A whole read of the file, whole or through a window, as the hook is handed it.
    private static func payload(command: String = "cat \(file)", id: String = "toolu_w1", extra: [String: Any] = [:]) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": id].merging(extra) { $1 }
    }

    /// The digest of `file` as the answerer built it: `served` bytes standing in for `source`.
    private static func digest(served: Int, source: Int) -> InPlaceAnswerer.Outcome {
        let reason = "sift answered this with `digest \(file)` instead of running it\(InPlaceAnswer.openingSuffix)\n\nbody"
        let call = InPlaceAnswerer.Call(tool: "digest", target: file, bytes: AnswerBytes(served: served, source: source))
        return .answered(InPlaceAnswerer.Answered(reason: reason, calls: [call], root: "/repo", milliseconds: 1))
    }

    private static func judged(_ payload: [String: Any], answers served: Int, of source: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> Judged {
        let scratch = try TemporaryDirectory.make("not-worth-the-turn")
        let suppressions = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String
        let lookup = try #require(PreToolUseCommand.lookup(command: command, payload: payload, in: "/repo", noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        let outcome = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: payload["agent_id"] as? String),
            payload: payload,
            command: command,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions,
            answerer: { _, _, _ in Self.digest(served: served, source: source) }
        )
        return Judged(outcome: outcome, scratch: scratch)
    }

    /// A file too small for the digest to pay is let through, logged as `notWorthTheTurn`, and the verdict names the rule.
    @Test
    func aSmallFileIsLetThroughAndLogged() throws {
        let judged = try Self.judged(Self.payload(), answers: 1000, of: 4000)

        #expect(judged.outcome.json == nil)
        #expect(judged.outcome.verdict.token == "allowed")
        #expect(judged.outcome.verdict.rule == "notWorthTheTurn")
        #expect(judged.suppressions.contains("\"notWorthTheTurn\""), "\(judged.suppressions)")
        #expect(SuppressionLog.callsLetThrough(in: judged.scratch.appendingPathComponent("suppressions.jsonl")) == ["toolu_w1": .notWorthTheTurn])
    }

    /// A large file is answered as before.
    @Test
    func aLargeFileIsAnswered() throws {
        let judged = try Self.judged(Self.payload(), answers: 8000, of: 40000)

        #expect(judged.outcome.verdict.token == "in-place")
        #expect(judged.outcome.json != nil)
        #expect(!judged.suppressions.contains("notWorthTheTurn"), "\(judged.suppressions)")
    }

    /// A window of the same small file is not judged by the rule: its answer stands as the window rules decide.
    @Test
    func aWindowIsNotJudgedByTheRule() throws {
        let judged = try Self.judged(Self.payload(command: "sed -n 1,40p \(Self.file)"), answers: 1000, of: 4000)

        #expect(judged.outcome.verdict.token == "in-place")
        #expect(!judged.suppressions.contains("notWorthTheTurn"), "\(judged.suppressions)")
    }

    /// A transcript for the session and one for the subagent, the one at `parent` tokens and the other at `own`.
    private static func contexts(parent: Int, own: Int?) throws -> [String: Any] {
        let directory = try TemporaryDirectory.make("not-worth-the-turn-transcripts")
        let session = directory.appendingPathComponent("s1.jsonl")
        try Self.write([Self.assistant(input: 1, read: parent - 1, created: 0)], to: session)
        if let own {
            try Self.write([Self.assistant(input: 1, read: own - 1, created: 0)], to: directory.appendingPathComponent("s1/subagents/agent-a1.jsonl"))
        }
        return ["transcript_path": session.path, "agent_id": "a1"]
    }

    /// A file of 12 KB with a digest a fifth of it is worth answering in a context of 20k and not in one of 120k, and the decision follows the subagent's own context, whatever the session's was.
    @Test
    func theDecisionFollowsTheSubagentsOwnContext() throws {
        let small = try Self.judged(Self.payload(extra: Self.contexts(parent: 120_000, own: 20000)), answers: 2400, of: 12000)
        let large = try Self.judged(Self.payload(extra: Self.contexts(parent: 20000, own: 120_000)), answers: 2400, of: 12000)

        #expect(small.outcome.verdict.token == "in-place")
        #expect(large.outcome.verdict.token == "allowed")
        #expect(large.outcome.verdict.rule == "notWorthTheTurn")
    }

    /// A subagent whose own transcript cannot be found is judged at the default context, never at the session's: the session's 120k would have let this read run.
    @Test
    func aSubagentWithNoTranscriptOfItsOwnIsJudgedAtTheDefault() throws {
        let judged = try Self.judged(Self.payload(extra: Self.contexts(parent: 120_000, own: nil)), answers: 2400, of: 12000)

        #expect(judged.outcome.verdict.token == "in-place")
    }

    /// A read let through on this rule prints no answer, so it writes no answered-log line and no marker; the same call answered writes both.
    @Test
    func aLetThroughWritesNoAnsweredLogLineAndNoMarker() throws {
        let scratch = try TemporaryDirectory.make("not-worth-the-turn-log")
        let log = AnsweredLog(fileURL: scratch.appendingPathComponent("answered.jsonl"), markers: scratch.appendingPathComponent("answers", isDirectory: true))
        let payload = Self.payload()

        let letThrough = try Self.judged(payload, answers: 1000, of: 4000)
        #expect(PrintedAnswer.recorded(letThrough.outcome, payload: payload, in: log) == nil)
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answered.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answers").path))

        let answered = try Self.judged(payload, answers: 8000, of: 40000)
        #expect(PrintedAnswer.recorded(answered.outcome, payload: payload, in: log) != nil)
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("answers/toolu_w1").path))
    }

    // MARK: - The accounting

    /// The audit reads the logged let-through back as a lookup withheld on worth under its own rule, and counts it in the total.
    @Test
    func theLetThroughIsCountedAsWithheldOnWorth() {
        #expect(TextSearch.Rule(loggedAs: .notWorthTheTurn) == .notWorthTheTurn)
        #expect(SwiftLookup.cold(file: "Sources/App/Depot.swift", missed: nil).scored(letThroughAs: .notWorthTheTurn) == .withheldOnWorth(rule: .notWorthTheTurn))
        var tally = TranscriptTally()
        tally.fold(.lookup(.withheldOnWorth(rule: .notWorthTheTurn)))

        #expect(tally.withheldOnWorthCauses.notWorthTheTurn == 1)
        #expect(tally.withheldOnWorth == 1)
        #expect(tally.cold == 0)
    }
}

extension NotWorthTheTurnTests {
    struct Judged {
        let outcome: (json: String?, verdict: PreToolUseCommand.Verdict)
        let scratch: URL

        var suppressions: String {
            (try? String(contentsOf: scratch.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)) ?? ""
        }
    }
}

extension NotWorthTheTurnTests {
    /// A Swift leg too small for its digest to pay is let through as `notWorthTheTurn` on a compound line too, with no note telling the line to make the call the rule judged a loss.
    @Test
    func aSmallFileOnACompoundLineIsLetThroughOnWorth() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let decided = try await BatchedReadNoteTests.decide("cat Sources/App/Depot.swift; ls", in: root)

        #expect(decided.verdict == "allowed\t\tnotWorthTheTurn")
        #expect(decided.logged == ["notWorthTheTurn"])
        #expect(!(decided.json ?? "").contains("put that on the line"), "\(decided.json ?? "")")
    }

    /// A Swift leg worth answering keeps the batched miss and its note on a compound line.
    @Test
    func aLargeFileOnACompoundLineKeepsTheNote() async throws {
        let root = try await WorthAnsweringFixture.repository()

        let decided = try await BatchedReadNoteTests.decide("cat Sources/App/Depot.swift; ls", in: root)

        let note = try #require(BatchedReadNoteTests.specific(decided.json)?["additionalContext"] as? String)

        #expect(note.contains("put that on the line in place of the read"), "\(note)")
        #expect(decided.verdict == "allowed\t\totherStatementsRun")
        #expect(decided.logged == ["otherStatementsRun"])
    }
}
