//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP

/// A hook that records the prompt the last call it judged carried, so a test can read back what `TranscriptReplay.replay` handed a call under `TranscriptReplay.promptKey` without judging anything itself.
final class PromptSpyHook: ReplayHook {
    var lastPrompt: LatestPrompt?

    func verdict(payload: [String: Any], cwd _: String, at _: Date?, decides _: Bool) -> ReplayVerdict? {
        lastPrompt = LatestPrompt.ofCall(payload)
        return ReplayVerdict(token: "allowed", rule: "noLookup")
    }

    func answered(payload _: [String: Any], cwd _: String, at _: Date?) {}

    func locatedOnlyByAnswers(_: String, payload _: [String: Any]) -> Bool {
        false
    }
}
