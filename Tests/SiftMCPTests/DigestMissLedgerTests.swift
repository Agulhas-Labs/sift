//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The live hook notes a digest in the advice ledger when the call is about to run, before any answer exists; `post-tool-use` takes the note back when the answer turns out to be a miss, so the window that follows is judged as a cold one.
@Suite(.temporaryDirectories)
struct DigestMissLedgerTests {
    private static let file = ListedWideWindowTests.file

    /// A `sift` hook subcommand run as the harness runs it, against `home`'s advice directory and usage log: what it printed.
    private static func hook(
        _ subcommand: String,
        _ payload: [String: Any],
        arguments: [String] = [],
        in root: URL,
        home: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        let process = Process()
        process.executableURL = binary
        process.arguments = [subcommand] + arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_HOME"] = home.appendingPathComponent("sift").path
        // A suite run under a live harness has that harness among the hook's ancestors, and its real server on record.
        environment["SIFT_SERVER_LOG"] = home.appendingPathComponent("server.jsonl").path
        environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
        environment["SIFT_NO_ADVICE"] = nil
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("claude").path
        environment["CLAUDE_PROJECT_DIR"] = nil
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        input.fileHandleForWriting.closeFile()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: printed, encoding: .utf8) ?? ""
    }

    /// The verdict token the hook gives `payload`: `allowed`, or the refusal or in-place answer it gave instead.
    private static func token(of payload: [String: Any], in root: URL, home: URL) throws -> String {
        let line = try hook("pre-tool-use", payload, arguments: ["--verdict"], in: root, home: home)
        return String(line.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
    }

    private static func payload(_ tool: String, _ input: [String: Any], root: URL, session: String) -> [String: Any] {
        ["tool_name": tool, "tool_input": input, "session_id": session, "cwd": root.path]
    }

    /// The hook's payload for the window of 150 lines of the file.
    private static func window(root: URL, session: String) -> [String: Any] {
        payload("Bash", ["command": "head -150 \(file)"], root: root, session: session)
    }

    /// The digest of `target` over `root`, as the renderer answers it.
    private static func answer(_ target: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        return try engine.digest(target: target, options: DigestOptions())
    }

    /// The review's reproduction: a window is refused, a digest of a member the file does not have is noted before it is answered and then answered as a miss, and the same window is refused still.
    @Test(arguments: Shape.allCases)
    func aMissedDigestLeavesTheWindowRefused(shape: Shape) async throws {
        let root = try ListedWideWindowTests.repository()
        let home = try TemporaryDirectory.make("miss-ledger")
        let session = "miss-ledger-\(shape)"
        let missed = try await Self.answer("Ledger.nosuchmember", in: root)
        try #require(DigestMiss.isMiss(inAnswer: missed), "the fixture's miss is not one: \(missed)")
        try #expect(Self.token(of: Self.window(root: root, session: session + "-cold"), in: root, home: home) != "allowed")

        let digest = shape.call(target: "Ledger.nosuchmember", root: root, session: session)
        _ = try Self.hook("pre-tool-use", digest, in: root, home: home)
        var answered = digest
        answered["tool_response"] = shape.response(missed)
        _ = try Self.hook("post-tool-use", answered, in: root, home: home)

        try #expect(Self.token(of: Self.window(root: root, session: session), in: root, home: home) != "allowed")
    }

    /// The control: the same sequence with a digest that served the file excuses the window, so the test above is not refused for another reason.
    @Test(arguments: Shape.allCases)
    func aServedDigestStillExcusesTheWindow(shape: Shape) async throws {
        let root = try ListedWideWindowTests.repository()
        let home = try TemporaryDirectory.make("served-ledger")
        let session = "served-ledger-\(shape)"
        let served = try await Self.answer("Ledger", in: root)
        try #require(!DigestMiss.isMiss(inAnswer: served))

        let digest = shape.call(target: "Ledger", root: root, session: session)
        _ = try Self.hook("pre-tool-use", digest, in: root, home: home)
        var answered = digest
        answered["tool_response"] = shape.response(served)
        _ = try Self.hook("post-tool-use", answered, in: root, home: home)

        try #expect(Self.token(of: Self.window(root: root, session: session), in: root, home: home) == "allowed")
    }

    /// The replay judges the digest call (noting it) before the answer comes back, and takes the note back when the answer is a miss; a served answer keeps it.
    @Test(arguments: [true, false])
    func theReplayTakesBackTheNoteOfAMissedDigest(missed: Bool) async throws {
        let root = try ListedWideWindowTests.repository()
        let answer = try await Self.answer(missed ? "Ledger.nosuchmember" : "Ledger", in: root)
        let hook = try HookReplay(directory: TemporaryDirectory.make("replay-miss"), timeBudget: 60, roots: RootDiscovery { _ in root })
        let payload: [String: Any] = [
            "tool_name": "mcp__sift__digest",
            "tool_input": ["target": missed ? "Ledger.nosuchmember" : "Ledger", "root": root.path],
            "session_id": "replay-miss",
            TranscriptReplay.answerKey: answer,
        ]
        _ = hook.verdict(payload: payload, cwd: root.path, at: nil, decides: true)
        #expect(!hook.ledger.digests(session: "replay-miss").isEmpty)

        hook.answered(payload: payload, cwd: root.path, at: nil)

        #expect(hook.ledger.digests(session: "replay-miss").isEmpty == missed)
    }

    /// Real renderer output for each kind of miss is read as one, and the served answer beside them is not.
    @Test
    func theRendererSaysEveryKindOfMissInWordsTheSharedDefinitionReads() async throws {
        let root = try ListedWideWindowTests.repository()
        let kinds = [
            "Nosuchthing": "no symbol named",
            "Ledger.nosuchmember": "no symbol named",
            "Alpha.balance3": "its nearest members:",
            "Wrong.balance3": "could not resolve the path",
            "Ledg": "nearest symbols:",
        ]
        for (target, marker) in kinds {
            let answer = try await Self.answer(target, in: root)
            #expect(answer.contains(marker), "\(target): \(answer)")
            #expect(DigestMiss.isMiss(inAnswer: answer), "\(target): \(answer)")
        }
        let served = try await Self.answer("Ledger", in: root)

        #expect(!DigestMiss.isMiss(inAnswer: served))
    }
}

extension DigestMissLedgerTests {
    enum Shape: CaseIterable {
        case mcp
        case bash

        func call(target: String, root: URL, session: String) -> [String: Any] {
            switch self {
            case .mcp:
                DigestMissLedgerTests.payload("mcp__sift__digest", ["target": target, "root": root.path], root: root, session: session)
            case .bash:
                DigestMissLedgerTests.payload("Bash", ["command": "sift digest \(target)"], root: root, session: session)
            }
        }

        func response(_ answer: String) -> Any {
            switch self {
            case .mcp: [["type": "text", "text": answer]]
            case .bash: ["stdout": answer, "stderr": "", "interrupted": false]
            }
        }
    }
}
