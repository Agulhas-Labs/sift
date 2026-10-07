//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The worth rule judges a whole read of one Swift file answered with its digest, and no other shape.
///
/// A document's outline, a line of several reads and a `cat` of two files are never let through on worth, however small the answer's source.
@Suite(.temporaryDirectories)
struct WholeReadWorthExclusionTests {
    private static func payload(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_x1"]
    }

    /// The outcome of `command` where the answerer would answer with a digest of a 4 kB source in 1 kB, which the rule alone would let through.
    private static func outcome(of command: String) throws -> Decided {
        let scratch = try TemporaryDirectory.make("worth-exclusions")
        let log = scratch.appendingPathComponent("suppressions.jsonl")
        let suppressions = SuppressionLog(fileURL: log)
        let payload = payload(command)
        guard let lookup = PreToolUseCommand.lookup(command: command, payload: payload, in: "/repo", noting: suppressions, couldAnswer: { _, _ in true }) else {
            return Decided(verdict: PreToolUseCommand.Verdict(token: "allowed", rule: "notALookup"), logged: "")
        }
        let reason = "sift answered this with `digest /repo/Sources/App/Depot.swift` instead of running it\(InPlaceAnswer.openingSuffix)\n\nbody"
        let call = InPlaceAnswerer.Call(tool: "digest", target: "/repo/Sources/App/Depot.swift", bytes: AnswerBytes(served: 1000, source: 4000))
        let answered = InPlaceAnswerer.Outcome.answered(InPlaceAnswerer.Answered(reason: reason, calls: [call], root: "/repo", milliseconds: 1))
        let decided = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
            payload: payload,
            command: command,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: suppressions,
            answerer: { _, _, _ in answered }
        )
        return Decided(verdict: decided.verdict, logged: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    /// The control: a whole read of one Swift file is let through on worth, so the exclusions below are not passing by the rule being off.
    @Test
    func aWholeReadOfOneSwiftFileIsLetThroughOnWorth() throws {
        let decided = try Self.outcome(of: "cat Sources/App/Depot.swift")

        #expect(decided.verdict.rule == "notWorthTheTurn")
    }

    @Test(arguments: [
        "cat README.md",
        "cat Sources/App/Depot.swift Sources/App/Other.swift",
        "cat Sources/App/Depot.swift; cat Sources/App/Other.swift",
        "cat Sources/App/Depot.swift && cat README.md",
    ])
    func aShapeOtherThanOneSwiftFilesWholeReadIsNeverLetThroughOnWorth(command: String) throws {
        let decided = try Self.outcome(of: command)

        #expect(decided.verdict.rule != "notWorthTheTurn", "\(decided.verdict)")
        #expect(!decided.logged.contains("notWorthTheTurn"), "\(decided.logged)")
    }
}

extension WholeReadWorthExclusionTests {
    struct Decided {
        let verdict: PreToolUseCommand.Verdict
        let logged: String
    }
}
