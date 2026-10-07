//
// Copyright © Agulhas Labs
//

import Foundation

/// Tells a hook payload Cursor sent from one Claude Code sent, so the Claude Code hooks can stay silent under Cursor.
///
/// Cursor imports hooks from Claude Code's settings files, on by default, and runs them with its own payload. It delivers a refusal's reason to the user rather than the model (`permissionDecisionReason` becomes `user_message`), so a refused model never learns which call to make instead: every hook answers a Cursor payload with nothing at all.
public struct CursorHookPayload {
    /// Whether `payload` came from Cursor: it carries any of `cursor_version`, `conversation_id`, `generation_id` or `workspace_roots`, fields Cursor gives every hook (cursor.com/docs/agent/hooks, "Common input fields") and none a Claude Code payload has.
    ///
    /// Any one suffices, because it is unestablished that Cursor passes `cursor_version` on to an imported Claude Code hook.
    public static func recognises(_ payload: [String: Any]) -> Bool {
        cursorFields.contains { payload[$0] != nil }
    }

    private static let cursorFields = ["cursor_version", "conversation_id", "generation_id", "workspace_roots"]
}
