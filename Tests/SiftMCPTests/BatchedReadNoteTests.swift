//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A compound line the hook lets run whole for its other statements is handed one line of context naming the call that answers its Swift leg, and is neither approved nor refused by it.
@Suite(.temporaryDirectories)
struct BatchedReadNoteTests {
    /// The hook's decision on `command` run from `root`, answered by the real answerer, with the withholdings its suppression log recorded against the call.
    static func decide(_ command: String, in root: URL) async throws -> BatchedLineDecision {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        let decided = await InPlaceAnswerTests.onItsOwnThread { () -> (json: String?, verdict: String) in
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
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let logged = text.split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["rule"] as? String == "answerWithheld" && $0["call"] as? String == "toolu_line" }
            .compactMap { $0["symbol"] as? String }
        return BatchedLineDecision(json: decided.json, verdict: decided.verdict, logged: logged)
    }

    /// The `hookSpecificOutput` object of a hook's printed JSON.
    static func specific(_ json: String?) -> [String: Any]? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return object["hookSpecificOutput"] as? [String: Any]
    }

    /// `target` spelled relative to `directory`, as a caller standing in one repository names a file in another beside it.
    static func relative(_ target: URL, from directory: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        let shared = zip(from, to).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - shared) + to[shared...]).joined(separator: "/")
    }

    /// A Swift window beside a statement no answer reproduces runs whole, with a note naming the call that answered the window alone and no permission decision.
    @Test func aBatchedReadIsHandedTheCallThatAnswersIt() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)

        let decided = try await Self.decide("sed -n 1,200p Sources/App/Depot.swift; ls", in: root)

        let specific = try #require(Self.specific(decided.json))

        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] == nil)
        #expect(specific["permissionDecisionReason"] == nil)
        let note = try #require(specific["additionalContext"] as? String)
        #expect(note == "sift: the Swift read on this line is answered by `sift digest Sources/App/Depot.swift` — put that on the line in place of the read.", "\(note)")
        #expect(decided.verdict == "allowed\t\totherStatementsRun")
        #expect(decided.logged == ["otherStatementsRun"])
    }

    /// A read of a file in another repository is named by its path in that repository, with `--root` to reach it, never by a type name the caller's own tree would resolve instead.
    @Test func aReadOfASiblingRepositoryNamesItsPathAndRoot() async throws {
        let sibling = try await WorthAnsweringFixture.repository()
        let caller = try MCPTestRepo.make(declaring: "Gizmo")
        let path = Self.relative(sibling.appendingPathComponent("Sources/App/Depot.swift"), from: caller)

        let decided = try await Self.decide("cat \(path); ls", in: caller)

        let note = try #require(Self.specific(decided.json)?["additionalContext"] as? String)
        let call = try #require(note.firstMatch(of: /`sift digest Sources\/App\/Depot\.swift --root ([^`]+)`/), "\(note)")

        #expect(CanonicalPath.of(String(call.1)) == CanonicalPath.of(sibling.path), "\(note)")
        #expect(decided.verdict == "allowed\t\totherStatementsRun")
    }

    /// A file whose stem names no type is named by its path, since `digest` of the stem would find no symbol.
    @Test func aFileWhoseStemNamesNoTypeIsNamedByItsPath() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func restock\($0)() -> Int {\n        let count = \($0)\n        let doubled = count * 2\n        let tripled = count * 3\(WorthAnsweringFixture.comment)\n        let total = doubled + tripled\n        return total + count\n    }" }
        try ("extension Depot {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/DepotStore.swift"), atomically: true, encoding: .utf8)

        let decided = try await Self.decide("cat Sources/App/DepotStore.swift; ls", in: root)

        let note = try #require(Self.specific(decided.json)?["additionalContext"] as? String)

        #expect(note == "sift: the Swift read on this line is answered by `sift digest Sources/App/DepotStore.swift` — put that on the line in place of the read.", "\(note)")
    }

    /// A search on a line let run whole is called a search, not a read.
    @Test func aBatchedSearchIsCalledASearch() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let decided = try await Self.decide("grep -n 'func stock3()' Sources/App/Depot.swift; ls", in: root)

        let note = try #require(Self.specific(decided.json)?["additionalContext"] as? String)

        #expect(note.hasPrefix("sift: the Swift search on this line is answered by `sift "), "\(note)")
        #expect(note.hasSuffix("put that on the line in place of the search."), "\(note)")
        #expect(decided.verdict == "allowed\t\totherStatementsRun")
    }

    /// The same Swift read on a line the answer covers whole is still answered in place, with no note.
    @Test func aSwiftReadAloneIsStillAnsweredInPlace() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)

        let decided = try await Self.decide("sed -n 1,200p Sources/App/Depot.swift", in: root)

        let specific = try #require(Self.specific(decided.json))

        #expect(specific["permissionDecision"] as? String == "deny")
        #expect(specific["additionalContext"] == nil)
        #expect(decided.verdict.hasPrefix("in-place\t"), "\(decided.verdict)")
    }

    /// Legs that alone are withheld — a window no answer is smaller than (on worth), and a grep of one file its digest cannot prove (for another reason) — each with the rule it meets alone.
    static let withheldAlone = [
        ("sed -n 6,9p Sources/App/Depot.swift", "notSmaller"),
        (#"grep -n 'static\|case ' Sources/App/Depot.swift"#, "notExact"),
    ]

    /// A Swift leg that alone would be withheld is no batched miss: the line is logged under the leg's own rule, as the leg alone would be, and carries no note.
    @Test(arguments: withheldAlone)
    func aLegWithheldAloneIsLoggedUnderItsOwnRuleWithNoNote(leg: String, rule: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let alone = try await Self.decide(leg, in: root)
        #expect(alone.verdict == "allowed\t\t\(rule)", "the leg alone: \(alone.verdict)")

        let decided = try await Self.decide("\(leg); ls", in: root)

        #expect(decided.json == nil)
        #expect(decided.verdict == "allowed\t\t\(rule)")
        #expect(decided.logged == [rule])
    }
}
