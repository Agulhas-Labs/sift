//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// `TranscriptReplay.replay` builds each call's payload with the context's latest prompt (`ReplayCall(…, prompt: prompt)`), which is what lets the hook it replays against judge a whole Markdown read the prompt names exactly as the live hook would.
@Suite(.temporaryDirectories) struct ReplayLatestPromptTests {
    @Test func replayHandsEachCallTheLatestPromptItFollowed() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "read Docs/Plan.md and carry on"]],
            [
                "type": "assistant", "sessionId": "s1", "cwd": root.path, "timestamp": "2026-09-20T10:00:00Z",
                "message": ["content": [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "Docs/Plan.md"]]]],
            ],
        ]
        let transcript = try TemporaryDirectory.make("transcript").appendingPathComponent("session.jsonl")
        let text = try lines.map { try #require(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)) }.joined(separator: "\n") + "\n"
        try text.write(to: transcript, atomically: true, encoding: .utf8)

        let spy = PromptSpyHook()
        let probes = ReplayProbes(since: nil, until: nil, timeZone: .current, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, memberExists: { _, _, _ in true })
        _ = TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: spy)

        #expect(spy.lastPrompt == LatestPrompt(text: "read Docs/Plan.md and carry on", cwd: root.path))
    }
}
