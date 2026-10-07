//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The replay credits a `where` answer's located files as the live hook reads them off the usage log, so a window of a file the answer located is let through silently in both.
@Suite(.temporaryDirectories) struct WhereLocatesWindowTests {
    /// A `where` answered in the transcript, through the MCP tool or the CLI, locates its file for the window after it: `noLookup`, where the same window with no answer before it is not.
    @Test(arguments: [true, false])
    func aWindowAfterAWhereAnswerIsNoLookupInTheReplay(throughTheServer: Bool) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let answered = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let cold = try HookReplay(directory: TemporaryDirectory.make("hook-replay-cold"), timeBudget: InPlaceAnswerTests.roomy)
        let window: [String: Any] = ["session_id": "replayed-session", "tool_name": "Bash", "tool_input": ["command": "sed -n 1,3p Sources/App/Depot.swift"]]

        let verdicts = await InPlaceAnswerTests.onItsOwnThread {
            let call: [String: Any] = throughTheServer
                ? ["session_id": "replayed-session", "tool_name": "mcp__sift__where", "tool_input": ["symbol": "Depot"]]
                : ["session_id": "replayed-session", "tool_name": "Bash", "tool_input": ["command": "sift where Depot"]]
            let window: [String: Any] = ["session_id": "replayed-session", "tool_name": "Bash", "tool_input": ["command": "sed -n 1,3p Sources/App/Depot.swift"]]
            var result = call
            result[TranscriptReplay.answerKey] = "where Depot\ndeclarations (1):\n  App.Depot — struct — struct Depot — Sources/App/Depot.swift:2-30\n"
            _ = answered.verdict(payload: call, cwd: root.path, at: nil, decides: true)
            answered.answered(payload: result, cwd: root.path, at: nil)
            return (answered.verdict(payload: window, cwd: root.path, at: nil, decides: true), cold.verdict(payload: window, cwd: root.path, at: nil, decides: true))
        }

        #expect(verdicts.0 == ReplayVerdict(token: "allowed", rule: "noLookup"))
        // With no answer before it the window is a lookup, which the fixture's small file leaves unanswered.
        #expect(verdicts.1 == ReplayVerdict(token: "allowed", rule: "notSmaller"))
        // The context's own call located it, so the audit scores the window as the scan does, not as located by
        // an answer the hook gave in place.
        #expect(!answered.locatedOnlyByAnswers(root.appendingPathComponent("Sources/App/Depot.swift").path, payload: window))
    }

    /// A Bash line whose output cannot be pinned to the repository the CLI answered from locates nothing in the replay: behind a directory change the live CLI answered from the other directory, and beside another command the output that looks like an answer may be that command's.
    @Test(arguments: [
        ("cd /elsewhere && sift where Depot", "where Depot\ndeclarations (1):\n  App.Depot — struct — struct Depot — Sources/App/Depot.swift:2-30\n"),
        ("(cd /elsewhere && sift where Depot)", "where Depot\ndeclarations (1):\n  App.Depot — struct — struct Depot — Sources/App/Depot.swift:2-30\n"),
        ("sift search kind:enum; grep -r '^$' Sources", "Sources/App/Depot.swift:\n"),
    ])
    func aBashLookupTheReplayCannotPinLocatesNothing(command: String, output: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let replay = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)

        let verdict = await InPlaceAnswerTests.onItsOwnThread {
            let call: [String: Any] = ["session_id": "replayed-session", "tool_name": "Bash", "tool_input": ["command": command]]
            let window: [String: Any] = ["session_id": "replayed-session", "tool_name": "Bash", "tool_input": ["command": "sed -n 1,3p Sources/App/Depot.swift"]]
            var result = call
            result[TranscriptReplay.answerKey] = output
            _ = replay.verdict(payload: call, cwd: root.path, at: nil, decides: true)
            replay.answered(payload: result, cwd: root.path, at: nil)
            return replay.verdict(payload: window, cwd: root.path, at: nil, decides: true)
        }

        // The window is judged as it is with no answer before it, not let through as located.
        #expect(verdict == ReplayVerdict(token: "allowed", rule: "notSmaller"))
    }
}
