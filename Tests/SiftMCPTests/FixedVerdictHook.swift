//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP

/// A hook that lets every Bash call through as `noLookup` and withholds every `Read` over the size budget at a fixed size, so the replay section's listing is read apart from what the real hook decides.
struct FixedVerdictHook: ReplayHook {
    func verdict(payload: [String: Any], cwd _: String, at _: Date?, decides _: Bool) -> ReplayVerdict? {
        payload["tool_name"] as? String == "Read"
            ? ReplayVerdict(token: "allowed", rule: "overSize", answerBytes: 14321)
            : ReplayVerdict(token: "allowed", rule: "noLookup")
    }

    func answered(payload _: [String: Any], cwd _: String, at _: Date?) {}

    func locatedOnlyByAnswers(_: String, payload _: [String: Any]) -> Bool {
        false
    }
}
