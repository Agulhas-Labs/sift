//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// What the CLI's four query subcommands write to the usage log: one line per lookup, on the same terms the server writes its own.
///
/// Driven through the built binary rather than through `answer()`, because the claim is about the *process*: that a lookup served from a shell reaches `~/.sift/usage.jsonl` at all, that it reaches the file the environment names and no other, and that a CLI run carries no session it was not given. Calling the command's body would prove none of those.
@Suite(.temporaryDirectories)
struct CLIUsageLogTests {
    /// Every query subcommand records what it served, and only `digest` records what it stood in for.
    @Test
    func eachQuerySubcommandRecordsTheLookupItServed() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try Self.scratch()
        let log = scratch.appendingPathComponent("usage.jsonl")

        let served = try [
            ["where", "Depot"],
            ["digest", "Sources/App/Depot.swift"],
            ["search", "kind:struct"],
            ["strings", "Depot"],
        ].map { try Self.run($0, in: repo, usageLog: log, home: scratch) }
        let records = Self.records(in: log)

        #expect(records.count == 4)
        #expect(records.map { $0["tool"] as? String } == ["where", "digest", "search", "strings"])
        #expect(records.allSatisfy { $0["ok"] as? Bool == true })
        #expect(records.map { $0["target"] as? String } == ["Depot", "Sources/App/Depot.swift", "kind:struct", "Depot"])
        // The face, so a reader can tell a lookup the CLI answered from one the server did — and so the
        // latency percentiles can stay the server's, a CLI process having opened the index inside the call.
        #expect(records.allSatisfy { $0["via"] as? String == "cli" })
        // What was served, counted over the answer as it went to stdout — `emit`'s trailing newline aside,
        // which is this face's framing and not part of the answer the server would have counted.
        #expect(records.map { $0["outBytes"] as? Int } == served.map { $0.utf8.count - 1 })
        // The denominator belongs to the one query that has one. A `where`, a `search` and a `strings`
        // answer stand in for a grep nobody can size, and record no source rather than a fabricated zero.
        #expect(records.map { $0["srcBytes"] is Int } == [false, true, false, false])
        // The files a `where` or `search` answer listed, which locate them for a later window; no other answer
        // records any.
        #expect(records.map { ($0["located"] as? [String])?.contains("Sources/App/Depot.swift") } == [true, nil, true, nil])
        let digest = try #require(records.first { $0["tool"] as? String == "digest" })
        #expect(try #require(digest["srcBytes"] as? Int) > #require(digest["outBytes"] as? Int))
    }

    /// A call with no conversation behind it records no session, and one Claude Code named records that name and nothing else.
    ///
    /// The two halves are one claim: the *only* thing a CLI line's session ever comes from is the id the harness put in the environment. A `sift where` typed at a prompt has none, and the field has always tolerated a call with no caller — so there is nothing to fall back to and nothing that may be inferred from the rest of the environment, which is otherwise full of things that look session-shaped.
    @Test
    func aCallWithNoSessionRecordsNoneRatherThanInventingOne() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try Self.scratch()
        let unsessioned = scratch.appendingPathComponent("unsessioned.jsonl")
        let sessioned = scratch.appendingPathComponent("sessioned.jsonl")

        _ = try Self.run(["where", "Depot"], in: repo, usageLog: unsessioned, home: scratch)
        _ = try Self.run(["where", "Depot"], in: repo, usageLog: sessioned, home: scratch, session: "s-cli")

        #expect(try #require(Self.records(in: unsessioned).first)["session"] == nil)
        #expect(try #require(Self.records(in: sessioned).first)["session"] as? String == "s-cli")
    }

    /// A subagent's lookup through Bash names the subagent in its line, claimed from the slip the hook left for that Bash call — and a same-shaped MCP call's slip in flight under the same session is left for the server.
    ///
    /// Through the built binary, because the claim is about the process: that the argv it is started with is the argv the hook read off the shell line, and that it finds the hook's slip in the per-user directory the environment names.
    @Test
    func aSubagentsShellLookupCarriesTheSubagentAndLeavesTheServersSlip() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try Self.scratch()
        let log = scratch.appendingPathComponent("usage.jsonl")
        let callers = CallAttribution(directory: scratch
            .appendingPathComponent(SiftPaths.directoryName, isDirectory: true)
            .appendingPathComponent("callers", isDirectory: true))
        let server: [String: Any] = ["tool_name": "mcp__sift__where", "tool_input": ["symbol": "Depot"], "agent_id": "b0c1d2e3"]
        let shell: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "sift where Depot --root '\(repo.path)' 2>&1 | head -40"],
            "agent_id": "adae5f77",
        ]
        PreToolUseCommand.noteCaller(session: "s-cli", payload: server, into: callers)
        PreToolUseCommand.noteCaller(session: "s-cli", payload: shell, into: callers)

        _ = try Self.run(["where", "Depot"], in: repo, usageLog: log, home: scratch, session: "s-cli")

        #expect(try #require(Self.records(in: log).first)["agent"] as? String == "adae5f77")
        #expect(callers.take(session: "s-cli", tool: "where", target: "Depot") == "b0c1d2e3")
    }

    /// An answer the advice hook gives in place is still one line, now that the CLI logs too.
    ///
    /// The hook is an ordinary `sift` process, and it reaches its answer through an engine it opens itself (``InPlaceAnswerer``) rather than by running a query subcommand — so the recording belongs to the subcommand's own exit (``LoggedLookup``) and to nothing inside `SiftCore`, and one call produces one record however many faces are logging.
    @Test
    func anAnswerTheHookGivesInPlaceIsRecordedOnce() throws {
        let scratch = try Self.scratch()
        let log = scratch.appendingPathComponent("usage.jsonl")
        let lookup = try #require(PreToolUseCommand.lookup(
            command: #"grep -n 'static\|case ' Sources/App/Depot.swift"#,
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        ))

        _ = PreToolUseCommand.respond(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil),
            payload: [:],
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: log),
            suppressions: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            answerer: { _, _, _ in
                .answered(InPlaceAnswerer.Answered(
                    reason: "sift answered this with `digest Sources/App/Depot.swift` …",
                    calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 300, source: 3000))],
                    root: "/repo",
                    milliseconds: 80
                ))
            }
        )

        #expect(Self.records(in: log).count == 1)
        #expect(Self.records(in: log).first?["via"] as? String == "hook")
    }

    /// A target string the CLI serves as several names records each name's part, and locates and stands in for what the separate calls record, as the server's line does.
    @Test
    func aSplitDigestRecordsEachNamesPartAsTheSeparateCallsWould() async throws {
        // A package, so the module's digest lists its files under headings and the split line has files to locate.
        let repo = try MCPTestRepo.make()
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "struct Depot {\n    let one = 1\n}\n",
        ], to: repo)
        try await SiftEngine(directory: repo).ensureFresh()
        let scratch = try Self.scratch()
        let log = scratch.appendingPathComponent("usage.jsonl")

        for target in ["Depot App", "Depot", "App"] {
            _ = try Self.run(["digest", target], in: repo, usageLog: log, home: scratch)
        }
        let records = Self.records(in: log)
        try #require(records.count == 3)
        let split = records[0]
        let separate = Array(records.dropFirst())

        let parts = try #require(split["parts"] as? [[String: Any]])
        #expect(parts.compactMap { $0["target"] as? String } == ["Depot", "App"])
        #expect(parts.first?["file"] as? String == "Sources/App/Depot.swift")
        #expect(parts.first?["srcBytes"] as? Int == separate[0]["srcBytes"] as? Int)
        #expect(split["srcBytes"] as? Int == separate.compactMap { $0["srcBytes"] as? Int }.reduce(0, +))
        #expect(separate.allSatisfy { $0["miss"] == nil })
        let located = Set(separate.flatMap { $0["located"] as? [String] ?? [] })
        #expect(!located.isEmpty)
        #expect(Set(split["located"] as? [String] ?? []) == located)
    }
}

extension CLIUsageLogTests {
    /// A directory this test owns, standing in for the home directory as well: the binary's registry and every other per-user file land there rather than in the real `~/.sift`.
    static func scratch() throws -> URL {
        let directory = try TemporaryDirectory.make("cli-usage").appendingPathComponent("cli-usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Runs this build's `sift` against `repo`, returning what it printed.
    static func run(
        _ arguments: [String],
        in repo: URL,
        usageLog: URL,
        home: URL,
        session: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let binary = try #require(
            BuiltExecutable.sift,
            "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
            sourceLocation: sourceLocation
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments + ["--root", repo.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_USAGE_LOG"] = usageLog.path
        // Assigning nil removes the key: the unsessioned case has to be a process the harness gave no
        // session, not one given an empty string, since those are two different claims about the field.
        environment["CLAUDE_CODE_SESSION_ID"] = session
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(
            process.terminationStatus == 0,
            "`sift \(arguments.joined(separator: " "))` exited \(process.terminationStatus)",
            sourceLocation: sourceLocation
        )
        return try #require(String(bytes: printed, encoding: .utf8), sourceLocation: sourceLocation)
    }

    static func records(in url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
