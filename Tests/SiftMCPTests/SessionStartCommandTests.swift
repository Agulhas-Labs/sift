//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers `session-start`'s wiring — what the Core tests of the primer and the resumption block cannot see: the stdin payload's `source` reaching the block's decision, the block landing after the primer, and a gather past its deadline costing the block and never the primer.
@Suite(.temporaryDirectories)
struct SessionStartCommandTests {
    @Test
    func aCompactPayloadAddsTheBlockAfterThePrimer() throws {
        let repo = try Self.repositoryWithAnEdit()

        let output = try #require(try Self.output(repo, source: "compact", deadline: 60))
        let halves = output.components(separatedBy: "\n\n**Picking back up:**\n")

        #expect(halves.count == 2)
        #expect(halves[0].isEmpty == false)
        #expect(halves[1].contains("declarations changed: +Gizmo"))
    }

    @Test
    func aStartupPayloadPrintsThePrimerAlone() throws {
        let repo = try Self.repositoryWithAnEdit()

        let output = try #require(try Self.output(repo, source: "startup", deadline: 60))

        #expect(output.contains("Picking back up") == false)
    }

    /// The hook's registered timeout kills the process outright, primer and all; the gather's own deadline, well inside it, gives up on the block alone.
    @Test
    func aGatherPastItsDeadlineCostsTheBlockAndNeverThePrimer() throws {
        let repo = try Self.repositoryWithAnEdit()

        let late = try #require(try Self.output(repo, source: "compact", deadline: 0))

        #expect(try Self.output(repo, source: "startup", deadline: 60) == late)
    }

    /// A subagent is told its session's server is not running where the transcript wrote the server off and nothing running says otherwise — and only a subagent, since at a session's start the server is still being launched beside the hook.
    @Test
    func aSubagentIsToldWhenItsSessionsServerIsProvenNotRunning() throws {
        let repo = try Self.repositoryWithAnEdit()
        let transcript = try Self.transcriptWritingTheServerOff()
        let log = try TemporaryDirectory.make("server-log").appendingPathComponent("server.jsonl")

        let subagent = try #require(try Self.output(repo, event: "SubagentStart", transcript: transcript, serverLog: log))
        #expect(subagent.contains(Self.notice))

        let session = try #require(try Self.output(repo, event: "SessionStart", transcript: transcript, serverLog: log))
        #expect(!session.contains(Self.notice))
    }

    /// A server recorded as started for the session and still running — checked against the kernel, as `sift status` checks it — keeps the notice out, whatever the transcript wrote.
    @Test
    func aSubagentWhoseSessionHasALiveServerIsNotToldItIsMissing() throws {
        let repo = try Self.repositoryWithAnEdit()
        let transcript = try Self.transcriptWritingTheServerOff()
        let log = try TemporaryDirectory.make("server-log").appendingPathComponent("server.jsonl")
        // This test process stands in for the server: its pid, stamped with the moment the kernel says it started,
        // and no parent, so only the session's id can match it.
        let started = try #require(ServerLifecycleReport.startTime(of: getpid()))
        ServerLifecycleLog(fileURL: log).recordStart(pid: getpid(), session: "s1", root: repo.path, now: started)

        let output = try #require(try Self.output(repo, event: "SubagentStart", transcript: transcript, serverLog: log))

        #expect(!output.contains(Self.notice))
    }
}

private extension SessionStartCommandTests {
    /// A committed repository with one uncommitted Swift file, so a block has a declaration to name.
    static func repositoryWithAnEdit() throws -> URL {
        let repo = try MCPTestRepo.make()
        try "struct Gizmo {}\n".write(to: repo.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        return repo
    }

    /// The opening words of the notice a subagent gets when its session's server is proven not to be running.
    static var notice: String {
        "This session's sift MCP server is not running"
    }

    /// A session transcript whose latest word on the server is the harness reporting it failed.
    static func transcriptWritingTheServerOff() throws -> URL {
        let url = try TemporaryDirectory.make("session").appendingPathComponent("s1.jsonl")
        let change: [String: Any] = [
            "type": "attachment",
            "attachment": ["type": "deferred_tools_delta", "addedNames": [String](), "failedMcpServers": [["name": IndexToolName.server]]],
        ]
        try (JSONSerialization.data(withJSONObject: change) + Data("\n".utf8)).write(to: url)
        return url
    }

    /// What the hook prints for an event in session `s1`, given where its transcript is and where its servers are logged.
    static func output(_ repo: URL, event: String, transcript: URL, serverLog: URL) throws -> String? {
        let ledger = try TemporaryDirectory.make("ledger").appendingPathComponent("run.jsonl")
        return SessionStartCommand.output(
            payload: [
                "cwd": repo.path,
                "hook_event_name": event,
                "source": "startup",
                "session_id": "s1",
                "transcript_path": transcript.path,
            ],
            cwd: nil,
            event: nil,
            runLedgerURL: ledger,
            serverLogURL: serverLog,
            resumptionDeadline: 60
        )
    }

    static func output(_ repo: URL, source: String, deadline: TimeInterval) throws -> String? {
        let ledger = try TemporaryDirectory.make("ledger").appendingPathComponent("run.jsonl")
        return SessionStartCommand.output(
            payload: ["cwd": repo.path, "hook_event_name": "SessionStart", "source": source],
            cwd: nil,
            event: nil,
            runLedgerURL: ledger,
            resumptionDeadline: deadline,
            // Only `deadline` is under test here. The declaration comparison's own quarter-second budget is lifted,
            // so a loaded machine cannot turn the names into a bare count.
            declarationParseBudget: .infinity
        )
    }
}
