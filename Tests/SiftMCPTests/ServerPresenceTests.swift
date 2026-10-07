//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Whether the server's tools are in a context now, read off the tool-list changes the harness writes into its transcript.
@Suite(.temporaryDirectories)
struct ServerPresenceTests {
    /// A tool-list change as the harness writes one: the tools brought in and taken out, the servers that failed, and the servers still connecting.
    private static func change(
        added: [String] = [],
        readded: [String] = [],
        removed: [String] = [],
        failed: [String] = [],
        pending: [String] = []
    ) -> [String: Any] {
        [
            "type": "attachment",
            "attachment": [
                "type": "deferred_tools_delta",
                "addedNames": added,
                "readdedNames": readded,
                "removedNames": removed,
                "failedMcpServers": failed.map { ["name": $0] },
                "pendingMcpServers": pending.map { ["name": $0] },
            ],
        ]
    }

    private static var tools: [String] {
        IndexToolName.qualified
    }

    /// A transcript file holding `objects` one to a line, with an ordinary turn between each, in a directory of its own.
    private static func transcript(_ objects: [[String: Any]], named name: String = "session", in directory: URL? = nil) throws -> URL {
        let directory = try directory ?? TemporaryDirectory.make("presence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let turn = #"{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}"#
        let lines = try objects.map { try String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) ?? "" }
        let url = directory.appendingPathComponent("\(name).jsonl")
        try (lines.flatMap { [$0, turn] }.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Each change says what it says about this server and nothing about any other.
    @Test
    func aToolListChangeSaysWhetherTheServerIsThere() {
        #expect(ServerPresence.verdict(of: Self.change(added: Self.tools)) == false)
        #expect(ServerPresence.verdict(of: Self.change(readded: Self.tools)) == false)
        #expect(ServerPresence.verdict(of: Self.change(failed: [IndexToolName.server])) == true)
        #expect(ServerPresence.verdict(of: Self.change(removed: Self.tools)) == true)
        #expect(ServerPresence.verdict(of: Self.change(removed: ["mcp__other__run"], failed: ["other"])) == nil)
        #expect(ServerPresence.verdict(of: ["type": "user", "message": ["content": [String]()]]) == nil)
    }

    /// A server still connecting is neither gone nor present: a change that lists it under `pendingMcpServers` must not read as gone even when it also takes its tools out or names it failed, and must not read as present either.
    @Test
    func aServerStillConnectingIsNeitherGoneNorPresent() {
        #expect(ServerPresence.verdict(of: Self.change(pending: [IndexToolName.server])) == nil)
        #expect(ServerPresence.verdict(of: Self.change(removed: Self.tools, pending: [IndexToolName.server])) == nil)
        #expect(ServerPresence.verdict(of: Self.change(failed: [IndexToolName.server], pending: [IndexToolName.server])) == nil)
        // A different server pending says nothing about this one.
        #expect(ServerPresence.verdict(of: Self.change(removed: Self.tools, pending: ["other"])) == true)
    }

    /// The latest word on the server decides: gone from the change that takes it away until one brings it back.
    @Test
    func theLatestChangeNamingTheServerDecides() throws {
        let arrived = Self.change(added: Self.tools)
        let failed = Self.change(removed: Self.tools, failed: [IndexToolName.server])
        let unrelated = Self.change(failed: ["other"])

        let gone = try Self.transcript([arrived, failed, unrelated])
        let back = try Self.transcript([arrived, failed, Self.change(readded: Self.tools)])
        let quiet = try Self.transcript([unrelated])
        defer {
            for url in [gone, back, quiet] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        #expect(ServerPresence.isGone(inTranscript: gone.path))
        #expect(!ServerPresence.isGone(inTranscript: back.path))
        #expect(!ServerPresence.isGone(inTranscript: quiet.path))
        #expect(!ServerPresence.isGone(inTranscript: nil))
        #expect(!ServerPresence.isGone(inTranscript: "/nonexistent/session.jsonl"))
    }

    /// A subagent's payload names its parent's transcript, and the subagent's own tool list is in its own file beside it.
    @Test
    func aSubagentIsReadFromItsOwnTranscript() throws {
        let session = try Self.transcript([Self.change(added: Self.tools)])
        let directory = session.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subagents = directory.appendingPathComponent("session/subagents", isDirectory: true)
        let own = try Self.transcript([Self.change(failed: [IndexToolName.server])], named: "agent-a1", in: subagents)

        let resolved = ServerPresence.transcript(ofSession: session.path, agent: "a1")

        #expect(resolved == own.path)
        #expect(ServerPresence.isGone(inTranscript: resolved))
        #expect(ServerPresence.transcript(ofSession: session.path, agent: "b2") == session.path)
        #expect(ServerPresence.transcript(ofSession: session.path, agent: nil) == session.path)
        #expect(!ServerPresence.isGone(inTranscript: session.path))
    }

    // MARK: Proven absent

    /// A lifecycle log in a directory of its own, holding the start line of one server spawned by pid 99 for `session` — or nothing at all.
    private static func lifecycleLog(startFor session: String?) throws -> URL {
        let url = try TemporaryDirectory.make("presence-log").appendingPathComponent("server.jsonl")
        if let session {
            ServerLifecycleLog(fileURL: url).recordStart(pid: 4242, session: session, root: "/repos/App", parent: 99)
        }
        return url
    }

    /// The harness writing the server off, with no server running to contradict it, is proof the session's server is not running.
    @Test
    func aServerWrittenOffWithNothingRunningIsProvenAbsent() throws {
        let failed = try Self.transcript([Self.change(added: Self.tools), Self.change(failed: [IndexToolName.server])])

        let empty = try Self.lifecycleLog(startFor: nil)
        #expect(ServerPresence.isProvenAbsent(session: "s1", transcript: failed.path, lifecycleLog: empty, callerTree: [], isRunning: { _ in true }))
        // A start for this session whose process is gone is no server.
        let stopped = try Self.lifecycleLog(startFor: "s1")
        #expect(ServerPresence.isProvenAbsent(session: "s1", transcript: failed.path, lifecycleLog: stopped, callerTree: [], isRunning: { _ in false }))
    }

    /// A live server this session can claim contradicts the transcript, found by the session's id or by the process that spawned it — the id goes stale across a `/clear`, while the host stays an ancestor of both the hook and its server.
    @Test
    func aLiveServerOfThisSessionMeansAbsenceIsNotProven() throws {
        let failed = try Self.transcript([Self.change(failed: [IndexToolName.server])])
        let ours = try Self.lifecycleLog(startFor: "s1")
        let renamed = try Self.lifecycleLog(startFor: "s0")

        #expect(!ServerPresence.isProvenAbsent(session: "s1", transcript: failed.path, lifecycleLog: ours, callerTree: [], isRunning: { _ in true }))
        #expect(!ServerPresence.isProvenAbsent(session: "s1", transcript: failed.path, lifecycleLog: renamed, callerTree: [7, 99], isRunning: { _ in true }))
        // Another session's live server, spawned by a process this one does not descend from, is not this session's.
        #expect(ServerPresence.isProvenAbsent(session: "s1", transcript: failed.path, lifecycleLog: renamed, callerTree: [7, 8], isRunning: { _ in true }))
    }

    /// A transcript that has not written the server off proves nothing, however empty the log: a log can be pointed elsewhere or trimmed, and a session's server is still being launched while its first hooks run.
    @Test
    func aTranscriptThatNeverWroteTheServerOffProvesNothing() throws {
        let empty = try Self.lifecycleLog(startFor: nil)
        let silent = try Self.transcript([Self.change(failed: ["other"])])
        let back = try Self.transcript([Self.change(failed: [IndexToolName.server]), Self.change(readded: Self.tools)])

        for transcript in [silent.path, back.path, nil, "/nonexistent/session.jsonl"] {
            #expect(!ServerPresence.isProvenAbsent(session: "s1", transcript: transcript, lifecycleLog: empty, callerTree: [], isRunning: { _ in false }))
        }
    }
}
