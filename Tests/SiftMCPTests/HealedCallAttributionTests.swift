//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A call the server rewrites before answering — a healed argument key, a `root:` lifted out of a search query — must still be attributed to the subagent that made it.
///
/// The hook leaves its slip from the arguments as the model sent them, before the server has healed anything, so the server has to claim the slip with those same arguments and log the call as what it resolved to. Claiming with the resolved arguments names a different target from the slip's, the slip is never matched, and the log line goes out with no agent — which is how a subagent's healed digest stops excusing that subagent's whole read of the file it digested.
@Suite(.temporaryDirectories)
struct HealedCallAttributionTests {
    private static var agent: String {
        "a1b2c3d4"
    }

    @Test
    func aSubagentsHealedDigestIsItsOwnAndExcusesItsWholeReadOfTheFile() async throws {
        let root = try MCPTestRepo.make()
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let path = "Sources/App/Alpha.swift"
        PreToolUseCommand.noteCaller(
            session: scratch.session,
            payload: ["tool_name": "mcp__sift__digest", "tool_input": ["path": path], "agent_id": Self.agent],
            into: scratch.callers
        )

        let entry = try await Self.loggedEntry(calling: "digest", with: ["path": path], on: root, scratch: scratch)

        #expect(entry["agent"] as? String == Self.agent)
        #expect(entry["target"] as? String == path)
        // The log's `session` field comes from the process environment, which a test must not set for every other
        // test in the run to see (`MCPServer.session`); it is stamped here exactly as `UsageLog` stamps it under a
        // real session, so what is checked is the rest of the line the server actually wrote.
        var stamped = entry
        stamped["session"] = scratch.session
        try JSONSerialization.data(withJSONObject: stamped).write(to: scratch.usage)
        let digested = DigestedFiles(usageLog: scratch.usage)
        #expect(digested.contains(root.appendingPathComponent(path).path, session: scratch.session, agent: Self.agent))
    }

    @Test
    func aSubagentsSearchWithItsRootInsideTheQueryIsItsOwn() async throws {
        let root = try MCPTestRepo.make()
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let query = "kind:struct root:\(root.path)"
        PreToolUseCommand.noteCaller(
            session: scratch.session,
            payload: ["tool_name": "mcp__sift__search", "tool_input": ["query": query], "agent_id": Self.agent],
            into: scratch.callers
        )

        let entry = try await Self.loggedEntry(calling: "search", with: ["query": query], on: root, scratch: scratch)

        #expect(entry["ok"] as? Bool == true)
        #expect(entry["agent"] as? String == Self.agent)
        // Logged as what was searched for, with the root that was lifted out of it recorded where roots go.
        #expect((entry["target"] as? String)?.contains("root:") == false)
    }

    /// One call through a real server, and the one usage line it wrote.
    static func loggedEntry(
        calling tool: String,
        with arguments: [String: Any],
        on root: URL,
        scratch: Scratch,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> [String: Any] {
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: scratch.usage),
            callers: scratch.callers,
            session: scratch.session
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try toServer.fileHandleForWriting.write(contentsOf: data)
        _ = await responses.next()
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value
        let lines = try String(contentsOf: scratch.usage, encoding: .utf8).split(separator: "\n")
        try #require(lines.count == 1, sourceLocation: sourceLocation)
        return try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }
}

extension HealedCallAttributionTests {
    /// A slip directory, a usage log and a session id of this test's own — never the machine's, which the real hook is writing to for the real session running this suite.
    struct Scratch {
        let directory: URL
        let session = "healed-call-tests-\(UUID().uuidString)"

        init() throws {
            directory = try TemporaryDirectory.make("healed")
                .appendingPathComponent("healed", isDirectory: true)
        }

        var callers: CallAttribution {
            CallAttribution(directory: directory.appendingPathComponent("callers", isDirectory: true))
        }

        var usage: URL {
            directory.appendingPathComponent("usage.jsonl")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
