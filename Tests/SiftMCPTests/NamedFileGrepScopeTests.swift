//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A grep whose operands are only Swift files it names is answered about those files or let through, never with a `where` that lists sites in files it did not name; a grep of a tree keeps the `where` it was always answered with.
@Suite(.temporaryDirectories)
struct NamedFileGrepScopeTests {
    /// A package whose property `level` is declared and read in one file and read or written in two others, built with an index store so a `where` has its reads and writes to list.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gauge.swift": "public struct Gauge {\n    public var level: Int = 0\n    public func doubled() -> Int { self.level * 2 }\n}\n",
            "Sources/App/Reader.swift": "func read(_ gauge: Gauge) -> Int {\n    gauge.level\n}\n",
            "Sources/App/Writer.swift": "func write(_ gauge: inout Gauge) {\n    gauge.level = 3\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The hook's whole decision on `command` run in `root`, with the real answerer on the built fixture: the in-place reading it takes the command as, and what it decided.
    private static func decision(on command: String, in root: URL) async throws -> (inPlace: InPlaceShape.Match?, verdict: PreToolUseCommand.Verdict) {
        let backoff = try InPlaceAnswerTests.backoff()
        let directory = try TemporaryDirectory.make("named-scope").appendingPathComponent("named-scope")
        let suppressions = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        guard let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: root.path,
            noting: suppressions,
            couldAnswer: { _, _ in true }
        ) else {
            return (nil, PreToolUseCommand.Verdict(token: "allowed"))
        }
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1"],
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
                suppressions: suppressions,
                answerer: { match, serverGone, _ in
                    InPlaceAnswerer.answer(
                        match.call,
                        from: match.directory,
                        serverGone: serverGone,
                        wholeCommand: match.isWholeCommand,
                        timeBudget: InPlaceAnswerTests.roomy,
                        backoff: backoff
                    )
                }
            )
        }
        return (lookup.inPlace, outcome.verdict)
    }

    /// A member-access grep of two files, or of one, that each use the name is let through: the name's `where` would list the declaring file the grep never named, and no answer scoped to the named files accounts for a use.
    @Test(arguments: [
        #"grep -n '\.level' Sources/App/Reader.swift Sources/App/Writer.swift"#,
        #"grep -n '\.level' Sources/App/Reader.swift"#,
        #"grep -rn '\.level' Sources/App/Reader.swift Sources/App/Writer.swift"#,
        "grep -n level Sources/App/Reader.swift Sources/App/Writer.swift",
    ])
    func aGrepOfNamedFilesIsNotAnsweredFromFilesItDidNotName(command: String) async throws {
        let root = try await Self.builtPackage()

        let decided = try await Self.decision(on: command, in: root)

        #expect(decided.inPlace == nil)
        #expect(decided.verdict.token == "allowed")
        #expect(decided.verdict.reason == nil)
    }

    /// A member's declaration grepped in named files is still answered by those files' own members, and by nothing outside them.
    @Test
    func aDeclarationGrepOfNamedFilesKeepsItsScopedAnswer() async throws {
        let root = try await Self.builtPackage()

        let decided = try await Self.decision(on: "grep -n 'var level' Sources/App/Gauge.swift Sources/App/Reader.swift", in: root)
        let reason = try #require(decided.verdict.reason)

        #expect(decided.verdict.token == "in-place")
        #expect(decided.verdict.call?.hasPrefix("digest ") == true)
        #expect(!reason.contains("Writer.swift"))
    }

    /// A grep of a tree for the same member access keeps the one `where` it was answered with, every site the tree holds listed.
    @Test
    func aRecursiveGrepOfATreeKeepsItsWhereAnswer() async throws {
        let root = try await Self.builtPackage()

        let decided = try await Self.decision(on: #"grep -rn '\.level' Sources"#, in: root)
        let reason = try #require(decided.verdict.reason)
        let body = reason.split(separator: "\n", omittingEmptySubsequences: false).drop { !$0.hasPrefix("tree: ") }.dropFirst().joined(separator: "\n")

        #expect(decided.inPlace?.call == .symbols(names: ["level"], paths: ["Sources"]))
        #expect(decided.verdict.token == "in-place")
        #expect(decided.verdict.call == "where level")
        #expect(body == [
            "where level",
            "mode: syntactic + semantic (index store via .build)",
            "",
            "declarations (1):",
            "  App.Gauge.level — var — public var level: Int = 0 — Sources/App/Gauge.swift:2",
            "",
            "reads and writes of App.Gauge.level (3):",
            "  Sources/App/Gauge.swift (1):",
            "    :3  doubled() — read  | public func doubled() -> Int { self.level * 2 }",
            "  Sources/App/Reader.swift (1):",
            "    :2  read(_:) — read  | gauge.level",
            "  Sources/App/Writer.swift (1):",
            "    :2  write(_:) — write  | gauge.level = 3",
            "",
            "reads and writes: written code only — the store records none made by a synthesized conformance (Equatable, Hashable, Codable) or by name at runtime, so a short or empty list is not proof a property is unused",
            "",
            "No saving is claimed: a `where` answer stands in for a search's output, which was never produced, so there is nothing measured to set it against.",
        ].joined(separator: "\n"))
    }
}
