//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The replay notes a call made through the CLI the way the live hook does.
@Suite(.temporaryDirectories)
struct ReplayShellCallNotedTests {
    @Test
    func aBashSiftWhereIsNotedAsMade() throws {
        let repo = try MCPTestRepo.make(declaring: "Shell")
        let hook = try HookReplay(directory: TemporaryDirectory.make("replay-shell"), timeBudget: 60)
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "sift where Shell"],
            "session_id": "replay-shell",
        ]

        _ = hook.verdict(payload: payload, cwd: repo.path, at: nil, decides: true)

        let offered = IndexSuggestion.rooted(["where Shell"], at: CallerRoot.root(forCallerIn: repo.path))
        let key = AdviceContext.resolve(sessionID: "replay-shell", transcriptPath: nil).key

        #expect(hook.ledger.decide(session: key, command: "grep -rn Shell Sources", offering: offered) == .allow)
    }
}
