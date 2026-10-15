//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A `cat` naming several Swift files is weighed file by file, as a `cat` of each is: answered in place where any file's digest is worth the turn, with that file's digest and every other file's source under its own heading, and let through on worth where none is.
@Suite(.temporaryDirectories)
struct HookMultiFileCatTests {
    /// A repository holding `Large` and `Other`, each a file whose digest is worth the turn at the default context, and `Medium`, `Small` and `Tiny`, files whose digest is not.
    private static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let write = { (name: String, members: Int, bodyLines: Int) in
            let body = (1 ... bodyLines).map { "        let value\($0) = count * \($0) + offset" }.joined(separator: "\n")
            let functions = (1 ... members).map { "    func step\($0)(count: Int, offset: Int) -> Int {\n\(body)\n        return count\n    }" }
            try ("/// A \(name).\nstruct \(name) {\n" + functions.joined(separator: "\n") + "\n}\n")
                .write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }
        try write("Large", 30, 20)
        try write("Other", 30, 20)
        try write("Medium", 10, 8)
        try write("Small", 10, 8)
        try write("Tiny", 10, 8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The hook's verdict for `command`, answered by the real answerer against `root`, with the advice ledger kept in `advice`, and the suppression log's rules.
    private static func decide(_ command: String, in root: URL, advice: URL) async throws -> Decided {
        let backoff = try InPlaceAnswerTests.backoff()
        let usage = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        let verdict = await InPlaceAnswerTests.onItsOwnThread { () -> PreToolUseCommand.Verdict? in
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "session_id": "s1", "tool_use_id": "toolu_cat"]
            guard let lookup = PreToolUseCommand.lookup(command: command, payload: payload, in: root.path, noting: SuppressionLog(fileURL: log), couldAnswer: { _, _ in true }) else {
                return nil
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
            ).verdict
        }
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let rules = logged.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["rule"] as? String
        }
        return Decided(verdict: verdict, rules: rules, logged: logged)
    }

    private static func decide(_ command: String, in root: URL) async throws -> Decided {
        try await decide(command, in: root, advice: TemporaryDirectory.make("advice"))
    }

    /// The re-run of an answered read is let through as the re-run of a `cat` of one answered file is.
    @Test
    func anAnsweredCatOfSeveralFilesIsLetThroughOnItsRerunAsOneFilesIs() async throws {
        let root = try await Self.repository()
        // The `cat` of one file runs in a repository of its own, so the digest it is served excuses no read of the other's files.
        let alone = try await Self.repository()
        let advice = try TemporaryDirectory.make("advice-rerun")
        let single = "cat Sources/App/Large.swift"
        let several = "cat Sources/App/Large.swift Sources/App/Other.swift"

        let first = try await Self.decide(single, in: alone, advice: advice)
        let singleRerun = try await Self.decide(single, in: alone, advice: advice)
        let answered = try await Self.decide(several, in: root, advice: advice)
        let rerun = try await Self.decide(several, in: root, advice: advice)

        #expect(first.verdict?.token == "in-place")
        #expect(answered.verdict?.token == "in-place", "\(String(describing: answered.verdict))")
        #expect(rerun.verdict?.token == "allowed", "\(String(describing: rerun.verdict))")
        #expect(rerun.verdict?.line == singleRerun.verdict?.line, "\(String(describing: rerun.verdict))")
    }

    /// The control: each large file read alone is answered, and each small one let through on worth.
    @Test
    func eachFileAloneIsJudgedAsTheLinesBelowRelyOn() async throws {
        let root = try await Self.repository()

        #expect(try await Self.decide("cat Sources/App/Large.swift", in: root).verdict?.token == "in-place")
        #expect(try await Self.decide("cat Sources/App/Medium.swift", in: root).verdict?.line == "allowed\t\tnotWorthTheTurn")
    }

    @Test
    func twoLargeFilesAreAnsweredWithTwoDigests() async throws {
        let root = try await Self.repository()

        let verdict = try #require(try await Self.decide("cat Sources/App/Large.swift Sources/App/Other.swift", in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        let large = try #require(reason.range(of: "Sources/App/Large.swift — module:"))
        let other = try #require(reason.range(of: "Sources/App/Other.swift — module:"))
        #expect(large.lowerBound < other.lowerBound)
        #expect(!reason.contains(SourcePassthrough.servedSourceSuffix), "\(reason)")
    }

    @Test(arguments: ["cat Sources/App/Large.swift Sources/App/Medium.swift", "cat -n Sources/App/Large.swift Sources/App/Medium.swift"])
    func aLargeFileAndASmallOneGetADigestAndTheSource(command: String) async throws {
        let root = try await Self.repository()

        let verdict = try #require(try await Self.decide(command, in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        #expect(reason.contains("struct Large — 30 members"), "\(reason)")
        let large = try #require(reason.range(of: "Sources/App/Large.swift — module: Sources"), "\(reason)")
        let medium = try #require(reason.range(of: "Sources/App/Medium.swift — module: Sources\n("), "\(reason)")
        #expect(large.lowerBound < medium.lowerBound)
        let mediumPart = reason[medium.lowerBound...]
        #expect(mediumPart.contains(SourcePassthrough.servedSourceSuffix), "\(reason)")
        #expect(mediumPart.contains("        let value8 = count * 8 + offset"), "\(reason)")
    }

    @Test
    func threeSmallFilesAreLetThroughOnWorth() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Medium.swift Sources/App/Small.swift Sources/App/Tiny.swift", in: root)

        #expect(decided.verdict?.line == "allowed\t\tnotWorthTheTurn", "\(String(describing: decided.verdict))")
        #expect(decided.rules == ["answerWithheld"], "\(decided.rules)")
        #expect(decided.logged.contains("notWorthTheTurn"), "\(decided.logged)")
        #expect(!decided.logged.contains("notAnswerable"), "\(decided.logged)")
    }

    @Test
    func aPipedCatOfSeveralFilesStaysFilteredOutput() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Large.swift Sources/App/Other.swift | grep step1", in: root)

        #expect(decided.verdict == nil, "\(String(describing: decided.verdict))")
        #expect(decided.rules == ["filteredOutput"], "\(decided.rules)")
    }
}

extension HookMultiFileCatTests {
    struct Decided {
        let verdict: PreToolUseCommand.Verdict?
        /// The rules the suppression log recorded, in order.
        let rules: [String]
        /// The suppression log as written.
        let logged: String
    }
}
