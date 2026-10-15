//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A `cat` naming several Swift files gets the verdict a `cat` of one gets on the same line: behind a `||` fallback that could print, numbered by `-n`, and piped into a window.
@Suite(.temporaryDirectories)
struct CatSeveralFilesVerdictTests {
    /// A repository holding `Large` and `Other`, files whose digest is worth the turn at the default context, `Medium` and `Small`, files whose digest is not, and `notes.txt`, no Swift file at all.
    static func repository() async throws -> URL {
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
        try "notes\n".write(to: root.appendingPathComponent("Sources/App/notes.txt"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The hook's verdict for `command`, answered by the real answerer against `root`, and the suppression log's rules.
    static func decide(_ command: String, in root: URL) async throws -> Decided {
        let backoff = try InPlaceAnswerTests.backoff()
        let advice = try TemporaryDirectory.make("advice")
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
        return Decided(verdict: verdict, rules: Self.rules(in: log))
    }

    /// The rules the log at `url` records, in order, or none where it was never written.
    private static func rules(in url: URL) -> [String] {
        let logged = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return logged.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["rule"] as? String
        }
    }

    // MARK: - Behind a `||` fallback

    /// The control: a `cat` of one file behind a fallback that could print is answered.
    @Test
    func oneFileBehindAFallbackIsAnswered() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Large.swift || echo fail", in: root)

        #expect(decided.verdict?.token == "in-place", "\(String(describing: decided.verdict))")
    }

    @Test
    func twoFilesBehindAFallbackAreAnsweredAsTheyAreWithoutIt() async throws {
        let root = try await Self.repository()

        let verdict = try #require(try await Self.decide("cat Sources/App/Large.swift Sources/App/Other.swift || echo fail", in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        let large = try #require(reason.range(of: "Sources/App/Large.swift — module:"), "\(reason)")
        let other = try #require(reason.range(of: "Sources/App/Other.swift — module:"), "\(reason)")
        #expect(large.lowerBound < other.lowerBound)
    }

    /// Each file is weighed as a `cat` of it alone is behind the fallback too: the small one is served as its source.
    @Test
    func aSmallFileBehindAFallbackIsServedAsItsSource() async throws {
        let root = try await Self.repository()

        let verdict = try #require(try await Self.decide("cat Sources/App/Large.swift Sources/App/Medium.swift || echo fail", in: root).verdict)

        #expect(verdict.token == "in-place", "\(verdict)")
        let reason = verdict.reason ?? ""
        let medium = try #require(reason.range(of: "Sources/App/Medium.swift — module: Sources\n("), "\(reason)")
        #expect(reason[medium.lowerBound...].contains(SourcePassthrough.servedSourceSuffix), "\(reason)")
    }

    @Test
    func noFileWorthItsDigestBehindAFallbackIsLetThroughOnWorth() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Medium.swift Sources/App/Small.swift || echo fail", in: root)

        #expect(decided.verdict?.line == "allowed\t\tnotWorthTheTurn", "\(String(describing: decided.verdict))")
    }

    /// A missing file fails the `cat`, so the fallback ran and printed: nothing the answer says covers that.
    @Test
    func aMissingFileBehindAFallbackIsNotAnswered() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Large.swift Sources/App/Gizmo.swift || echo fail", in: root)

        #expect(decided.verdict?.token == "allowed", "\(String(describing: decided.verdict))")
        #expect(decided.verdict?.rule == "notExact", "\(String(describing: decided.verdict))")
    }

    /// A file the index holds but `cat` cannot open fails the `cat` as a missing one does, after the first file printed.
    @Test
    func anUnreadableFileBehindAFallbackIsNotAnswered() async throws {
        let root = try await Self.repository()
        let other = root.appendingPathComponent("Sources/App/Other.swift").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: other)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: other) }

        let decided = try await Self.decide("cat Sources/App/Large.swift Sources/App/Other.swift || echo fail", in: root)

        #expect(decided.verdict?.token == "allowed", "\(String(describing: decided.verdict))")
    }

    @Test
    func aNonSwiftFileBehindAFallbackIsNotAnsweredAsSwift() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Large.swift Sources/App/notes.txt || echo fail", in: root)

        #expect(decided.verdict?.token != "in-place", "\(String(describing: decided.verdict))")
        let reason = decided.verdict?.reason ?? ""
        #expect(!reason.contains("notes.txt"), "\(reason)")
    }

    @Test
    func aFileNamedTwiceBehindAFallbackIsNotAnswered() async throws {
        let root = try await Self.repository()

        let decided = try await Self.decide("cat Sources/App/Large.swift Sources/App/../App/Large.swift || echo fail", in: root)

        #expect(decided.verdict?.token != "in-place", "\(String(describing: decided.verdict))")
    }
}

extension CatSeveralFilesVerdictTests {
    struct Decided {
        let verdict: PreToolUseCommand.Verdict?
        /// The rules the suppression log recorded, in order.
        let rules: [String]
    }
}
