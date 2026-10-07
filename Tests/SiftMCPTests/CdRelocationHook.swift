//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP

/// A hook that recovers a `cat` and lets every other Bash call through as `noLookup`, and calls a row located only for the one exact path it is built to answer for — so a replay's own relocation of a cold row is provable without the real hook's repository resolution or compression floor.
struct CdRelocationHook: ReplayHook {
    /// The one path `locatedOnlyByAnswers` answers true for.
    let locatedPath: String

    func verdict(payload: [String: Any], cwd _: String, at _: Date?, decides _: Bool) -> ReplayVerdict? {
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String ?? ""
        return command.hasPrefix("cat")
            ? ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: "sift digest Sources/App/Gizmo.swift")
            : ReplayVerdict(token: "allowed", rule: "noLookup")
    }

    func answered(payload _: [String: Any], cwd _: String, at _: Date?) {}

    func locatedOnlyByAnswers(_ path: String, payload _: [String: Any]) -> Bool {
        path == locatedPath
    }
}
