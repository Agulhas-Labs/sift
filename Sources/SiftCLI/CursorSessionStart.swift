//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// `session-start --agent cursor`: Cursor's `sessionStart` payload read as the Claude Code `SessionStart` payload the primer is written for.
///
/// Cursor's payload has no `cwd` and no `source`, so the directory is the first workspace root, and nothing is read that could draw the resumption block or the subagent primer: Cursor has neither a resumed start nor a subagent start to tell apart.
struct CursorSessionStart {
    /// The Claude Code payload `payload` stands for, or `nil` where it is not a `sessionStart` payload with an absolute workspace root.
    ///
    /// `nil` rather than the process directory: a directory the payload does not name is a guess, and the primer would describe whatever tree Cursor happened to launch the hook in.
    static func claudePayload(from payload: [String: Any]) -> [String: Any]? {
        guard payload["hook_event_name"] as? String == "sessionStart",
              let root = (payload["workspace_roots"] as? [Any])?.first as? String, root.hasPrefix("/")
        else {
            return nil
        }
        return ["hook_event_name": "SessionStart", "cwd": root]
    }
}
