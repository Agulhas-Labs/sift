//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The hook in a tree nobody may write lets a lookup run rather than build an index in memory from a parse of the whole tree, which a process of its own per call would pay on every call.
@Suite(.temporaryDirectories)
struct ReadOnlyHookTests {
    /// A whole read is withheld as `treeNotWritable` before any engine is opened, a bound reuse's included, and nothing is made under the tree.
    @Test
    func aReadInATreeNobodyMayWriteOpensNoEngine() async throws {
        let root = try Self.seed()
        try Self.chmod("a-w", root)
        defer { try? Self.chmod("u+w", root) }

        let (outcome, opened) = try await Self.outcome(of: #require(InPlaceShape.match(forShell: "cat Sources/App/Depot.swift", in: root.path)))

        #expect(outcome == .withheld(.treeNotWritable))
        #expect(opened == 0)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
    }

    /// Several lookups on one line are withheld the same way, before their one shared engine is opened.
    @Test
    func aLineOfSeveralLookupsInATreeNobodyMayWriteOpensNoEngine() async throws {
        let root = try Self.seed()
        try Self.chmod("a-w", root)
        defer { try? Self.chmod("u+w", root) }
        let match = try #require(InPlaceShape.match(forShell: "cat Sources/App/Alpha.swift; cat Sources/App/Depot.swift", in: root.path))
        try #require(match.isWholeCommand && match.lookups == 2, "\(match)")

        let (outcome, opened) = try await Self.outcome(of: match)

        #expect(outcome == .withheld(.treeNotWritable))
        #expect(opened == 0)
    }

    /// Through the hook: the read runs, nothing is printed or recorded as served, and the suppression log names why under the call's id.
    @Test
    func theHookLetsTheReadRunAndLogsWhy() async throws {
        let root = try Self.seed()
        let stores = try TemporaryDirectory.make("readonly-hook")
        try Self.chmod("a-w", root)
        defer { try? Self.chmod("u+w", root) }

        let output = try await Self.respond(toWholeReadOf: "Sources/App/Depot.swift", in: root, stores: stores)
        let suppressions = Self.lines(of: stores.appendingPathComponent("suppressions.jsonl"))

        #expect(output == nil)
        #expect(Self.lines(of: stores.appendingPathComponent("usage.jsonl")).isEmpty)
        #expect(suppressions.count == 1)
        #expect(suppressions.first?["rule"] as? String == "answerWithheld")
        #expect(suppressions.first?["symbol"] as? String == InPlaceAnswerer.Withholding.treeNotWritable.rawValue)
        #expect(suppressions.first?["call"] as? String == "toolu_readonly")
    }

    /// The same read of the same tree, left writable, is still answered with the file's digest.
    @Test
    func theSameReadInAWritableTreeIsStillAnswered() async throws {
        let root = try Self.seed()
        let stores = try TemporaryDirectory.make("readonly-hook")

        let response = try await Self.respond(toWholeReadOf: "Sources/App/Depot.swift", in: root, stores: stores)
        let output = try #require(response, "\(Self.lines(of: stores.appendingPathComponent("suppressions.jsonl")))")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(specific["permissionDecision"] as? String == "deny")
        #expect((specific["permissionDecisionReason"] as? String)?.hasPrefix("sift answered this with `digest Sources/App/Depot.swift` instead of running it") == true)
        #expect(Self.lines(of: stores.appendingPathComponent("suppressions.jsonl")).isEmpty)
    }
}

private extension ReadOnlyHookTests {
    /// A committed repository with no `.sift/`: `Alpha` from the shared fixture, and a `Depot` long enough that its digest compresses.
    static func seed() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let members = (1 ... 40).map { "    func stock\($0)() -> Int {\n        let count = \($0)\(WorthAnsweringFixture.comment)\n        let doubled = count * 2\n        return doubled + count\n    }" }
        try MCPTestRepo.add(["Sources/App/Depot.swift": "/// A depot.\nstruct Depot {\n" + members.joined(separator: "\n") + "\n}\n"], to: root)
        return root
    }

    /// What the answerer makes of `match`, with a reuse bound as a replay binds one, and how many engines that reuse opened.
    static func outcome(of match: InPlaceShape.Match) async throws -> (InPlaceAnswerer.Outcome, Int) {
        let backoff = try InPlaceAnswerTests.backoff()
        let reuse = EngineReuse()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            EngineReuse.$current.withValue(reuse) {
                InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
            }
        }
        return (outcome, reuse.opened)
    }

    /// What the hook prints for a whole `Read` of `path` in `root`, its logs and ledger kept in `stores`.
    static func respond(toWholeReadOf path: String, in root: URL, stores: URL) async throws -> String? {
        let backoff = try InPlaceAnswerTests.backoff()
        let file = root.appendingPathComponent(path).path
        let usage = stores.appendingPathComponent("usage.jsonl")
        let suppressions = stores.appendingPathComponent("suppressions.jsonl")
        return await InPlaceAnswerTests.onItsOwnThread { () -> String? in
            let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file], "session_id": "s1", "tool_use_id": "toolu_readonly"]
            guard let lookup = PreToolUseCommand.lookup(
                command: nil,
                payload: payload,
                in: root.path,
                noting: SuppressionLog(fileURL: suppressions),
                digested: DigestedFiles(usageLog: usage),
                couldAnswer: { _, _ in true }
            ) else {
                return "no lookup"
            }
            return PreToolUseCommand.respond(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
                payload: payload,
                cwd: root.path,
                ledger: AdviceLedger(directory: stores.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: usage),
                suppressions: SuppressionLog(fileURL: suppressions),
                answerer: { match, gone, _ in InPlaceAnswerer.answer(match.call, from: match.directory, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
            )
        }
    }

    /// Every JSON line of the log at `url`, none where there is no log.
    static func lines(of url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// `chmod -R <mode>` over `root`.
    static func chmod(_ mode: String, _ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
