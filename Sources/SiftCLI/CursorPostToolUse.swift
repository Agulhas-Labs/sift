//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// `post-tool-use --agent cursor`: Cursor's `postToolUse` payload read as the Claude Code payload the hook judges, and what it prints written back in Cursor's schema.
///
/// A probe saw Cursor report both a new file and a search-and-replace edit as `Write` with the file's whole new content and no content from before it; so an edit is judged as a Claude Code `Write` with nothing known of the prior file. Anything else it sends is not read at all.
struct CursorPostToolUse {
    /// The standard streams, carrying only what ``response(to:)`` makes of each line the hook would print for Claude Code.
    static let output = CommandOutput(
        keepsPartMarker: true,
        emit: { line in
            if let response = response(to: line) {
                StandardStreams.emit(response)
            }
        },
        emitRaw: { _ in },
        emitError: { StandardStreams.emitError($0) }
    )

    /// The Claude Code payload `payload` stands for, or `nil` where it is not a `postToolUse` payload of a `Write`, in the shape a probe recorded, with an absolute workspace root and a session.
    static func claudePayload(from payload: [String: Any]) -> [String: Any]? {
        guard payload["hook_event_name"] as? String == "postToolUse",
              payload["tool_name"] as? String == "Write",
              let input = payload["tool_input"] as? [String: Any],
              Set(input.keys).isSubset(of: ["file_path", "content"]),
              let path = input["file_path"] as? String, !path.isEmpty,
              let root = (payload["workspace_roots"] as? [Any])?.first as? String, root.hasPrefix("/"),
              let session = payload["session_id"] as? String ?? payload["conversation_id"] as? String
        else {
            return nil
        }
        var claude: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": input, "cwd": root, "session_id": session]
        claude["transcript_path"] = payload["transcript_path"] as? String
        return claude
    }

    /// What Cursor is told for the hook's Claude Code `output`, or `nil` where its schema has no room for it.
    ///
    /// Both of the hook's answers reach the model as context, the one carrier a probe saw delivered on `postToolUse`: the reuse nudge, and the parse block's reason, since no block of a call already made was probed.
    static func response(to output: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            return nil
        }
        if object["decision"] as? String == "block", let reason = object["reason"] as? String {
            return CursorHookOutput.additionalContext(reason)
        }
        guard let specific = object["hookSpecificOutput"] as? [String: Any],
              specific["hookEventName"] as? String == "PostToolUse",
              let context = specific["additionalContext"] as? String
        else {
            return nil
        }
        return CursorHookOutput.additionalContext(context)
    }
}
