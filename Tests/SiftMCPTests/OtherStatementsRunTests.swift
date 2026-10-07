//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A line holding a statement that prints what no answer reproduces runs whole, rather than being refused with an answer to one part of it.
@Suite(.temporaryDirectories)
struct OtherStatementsRunTests {
    /// Lines whose one answered lookup sits beside a statement nothing stands in for: a recursive grep over a directory and a document, a filtered grep over a glob, a grep of a text file, a `git grep`, an `ls`, a `git checkout`.
    static let unreproduced = [
        #"echo "=== Depot 1-200"; sed -n '1,200p' Sources/App/Depot.swift; echo "=== stock in hook"; grep -rn 'struct Depot\|stock' Sources Docs/Design.md 2>/dev/null | cut -c1-190 | head -50"#,
        #"grep -rn "47" Sources/App/*.swift | grep -i version | head -5; sed -n 1,200p Sources/App/Depot.swift; grep -n "alpha\|beta" Distribution/names.txt; git grep -n "alpha\|beta" origin/main -- Tests | head -3"#,
        "sed -n 1,200p Sources/App/Depot.swift; ls",
        "cat Sources/App/Depot.swift; cat Sources/App/Alpha.swift; ls",
        "sed -n 1,200p Sources/App/Depot.swift && git checkout -b feature",
    ]

    /// Lines whose every statement is an answered lookup, a literal `echo`, a `cd`, a fallback proven silent, a variable assignment or option, or a literal whose own standard error is sent away.
    static let reproduced = [
        "echo a; sed -n 1,200p Sources/App/Depot.swift",
        "cd Sources; sed -n 1,200p App/Depot.swift",
        "sed -n 1,200p Sources/App/Depot.swift || true",
        "echo ---; sed -n 1,200p Sources/App/Depot.swift; echo ---; grep -n 'func stock3()' Sources/App/Depot.swift",
        "X=1; sed -n 1,200p Sources/App/Depot.swift",
        "export X=1; sed -n 1,200p Sources/App/Depot.swift",
        "unset X; sed -n 1,200p Sources/App/Depot.swift",
        "set -e; sed -n 1,200p Sources/App/Depot.swift",
        "echo a 2>/dev/null; sed -n 1,200p Sources/App/Depot.swift",
    ]

    /// The rule an outcome was withheld under, spelled as the hook logs it, or `nil` for an answer.
    private static func withheld(_ outcome: InPlaceAnswerer.Outcome) -> String? {
        guard case let .withheld(why) = outcome else { return nil }
        return why.rawValue
    }

    /// The hook's decision on `command` run from `root`, answered by the real answerer, with its suppressions written to `log`.
    private static func decide(_ command: String, in root: URL, log: URL) async throws -> (json: String?, verdict: String) {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        return await InPlaceAnswerTests.onItsOwnThread { () -> (json: String?, verdict: String) in
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_line"]
            guard let lookup = PreToolUseCommand.lookup(
                command: command,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: log),
                couldAnswer: { _, _ in true }
            ) else {
                return (nil, "no lookup")
            }
            let decided = PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: AdviceLedger(directory: advice),
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: log),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) },
                serverPresence: { _, _ in false }
            )
            return (decided.json, decided.verdict.line)
        }
    }

    /// A line with a statement nothing reproduces is let run, under a rule of its own, and the withholding is logged under the call as every other is.
    @Test(arguments: unreproduced)
    func aStatementNothingReproducesLetsTheLineRun(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")

        let decided = try await Self.decide(command, in: root, log: log)

        // Never a denial or an approval: at most a note, which `BatchedReadNoteTests` pins.
        #expect(decided.json?.contains("permissionDecision") != true)
        #expect(decided.verdict == "allowed\t\totherStatementsRun")
        let text = try String(contentsOf: log, encoding: .utf8)
        let entries = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(entries.contains { $0["rule"] as? String == "answerWithheld" && $0["symbol"] as? String == "otherStatementsRun" && $0["call"] as? String == "toolu_line" })
    }

    /// A line whose every statement the answer reproduces is still answered in place.
    @Test(arguments: reproduced)
    func literalsMovesAndAnsweredLookupsAreStillAnswered(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")

        let decided = try await Self.decide(command, in: root, log: log)

        #expect(decided.json != nil)
        #expect(decided.verdict.hasPrefix("in-place\t"), "\(decided.verdict)")
    }

    /// A lookup the ledger already let through still prints its own output beside a new one, so the line runs rather than being denied with an answer to the new one alone.
    @Test
    func aLookupAlreadyLetThroughStillPrints() throws {
        let command = "grep -rn Depot Sources; sed -n 1,200p Sources/App/Depot.swift; echo done"
        let match = try #require(InPlaceShape.match(forShell: command, in: "/repo", ridingAlong: { $0.hasPrefix("grep") }))

        #expect(match.calls.map(\.readPath) == ["Sources/App/Depot.swift"])
        #expect(Self.withheld(InPlaceAnswerer.answer(match)) == "otherStatementsRun")
    }

    /// A window of a located file dropped beside another lookup prints lines the answer leaves out, so the line runs.
    @Test
    func aDroppedWindowLetsTheLineRun() throws {
        let match = try #require(InPlaceShape.match(forShell: "sed -n 1,5p Sources/App/Alpha.swift; cat Sources/App/Depot.swift", in: "/repo"))
        let rest = try #require(match.droppingWindows { $0.hasSuffix("Alpha.swift") })

        #expect(Self.withheld(InPlaceAnswerer.answer(match)) != "otherStatementsRun")
        #expect(Self.withheld(InPlaceAnswerer.answer(rest)) == "otherStatementsRun")
    }

    /// A compound line with no Swift lookup on it is no lookup at all, so the hook never touches it.
    @Test(arguments: ["git status; git checkout -b feature", "cd Sources && git checkout -b feature", "echo a; ls; git status"])
    func aLineWithNoLookupIsNeverTouched(command: String) throws {
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")

        #expect(InPlaceShape.match(forShell: command, in: "/repo") == nil)
        #expect(PreToolUseCommand.lookup(
            command: command,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: "/repo",
            noting: SuppressionLog(fileURL: log),
            couldAnswer: { _, _ in true }
        ) == nil)
    }
}
