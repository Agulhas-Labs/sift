//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// `pre-tool-use --agent cursor`: Cursor's `preToolUse` payload read as the Claude Code payload the hook's decisions are written against, and each decision written back in Cursor's response schema.
///
/// Both ends are a translation and nothing else, so one engine judges both harnesses. Only the tool inputs a probe of a real Cursor recorded are read, key for key; a payload carrying anything else is not read at all, because on Cursor a response that does not fit the schema can block the call, and silence is the one answer that never can.
struct CursorPreToolUse {
    /// The Claude Code payload `payload` stands for, or `nil` where it is not a `preToolUse` payload of a tool input this reads.
    ///
    /// The working directory is the first workspace root: Shell's own `cwd` has always come empty, and is taken only where it names a directory.
    static func claudePayload(from payload: [String: Any]) -> [String: Any]? {
        guard payload["hook_event_name"] as? String == "preToolUse",
              let name = payload["tool_name"] as? String,
              let input = payload["tool_input"] as? [String: Any],
              let root = (payload["workspace_roots"] as? [Any])?.first as? String, root.hasPrefix("/"),
              let tool = claudeTool(name, input: input)
        else {
            return nil
        }
        let shellDirectory = (input["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        var claude: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": tool.name, "tool_input": tool.input]
        claude["cwd"] = tool.name == "Bash" ? shellDirectory ?? root : root
        claude["session_id"] = payload["session_id"] as? String ?? payload["conversation_id"] as? String
        claude["transcript_path"] = payload["transcript_path"] as? String
        claude["tool_use_id"] = payload["tool_use_id"] as? String
        return claude
    }

    /// What Cursor is told for the hook's Claude Code `output`, or `nil` where its schema has no room for it.
    ///
    /// A refusal carries its reason as the message the model reads. An amended input carries over only for an index call, the `root:` amendment: a build is never rewritten on Cursor, since nothing establishes that the rewritten command costs the user no prompt there. Context for the model has no carrier a probe saw delivered, so it prints nothing.
    static func response(to output: String, toolName: String?) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let specific = object["hookSpecificOutput"] as? [String: Any]
        else {
            return nil
        }
        if specific["permissionDecision"] as? String == "deny", let reason = specific["permissionDecisionReason"] as? String {
            return CursorHookOutput.preToolUseDenial(message: reason)
        }
        guard specific["permissionDecision"] == nil,
              let input = specific["updatedInput"] as? [String: Any],
              IndexToolName.tool(named: toolName ?? "Bash") != nil
        else {
            return nil
        }
        return CursorHookOutput.preToolUseAmendment(input: input)
    }

    /// The Claude Code tool and input a Cursor tool call is, in the shapes a probe recorded.
    private static func claudeTool(_ name: String, input: [String: Any]) -> (name: String, input: [String: Any])? {
        let keys = Set(input.keys)
        switch name {
        case "Shell":
            guard keys.isSubset(of: ["command", "cwd", "timeout"]), let command = input["command"] as? String, !command.isEmpty else { return nil }
            return ("Bash", input)
        case "Read":
            guard keys == ["file_path"], let path = input["file_path"] as? String, !path.isEmpty else { return nil }
            return ("Read", input)
        case "Grep":
            guard keys.isSubset(of: ["pattern", "file_path"]), let pattern = input["pattern"] as? String, !pattern.isEmpty else { return nil }
            var read: [String: Any] = ["pattern": pattern]
            if let path = input["file_path"] {
                guard let path = path as? String else { return nil }
                read["path"] = path
            }
            return ("Grep", read)
        case "Write":
            guard keys.isSubset(of: ["file_path", "content"]), input["file_path"] is String else { return nil }
            return ("Write", input)
        default:
            guard let tool = IndexToolName.tool(namedByCursor: name, input: input) else { return nil }
            return (IndexToolName.prefix + tool, input)
        }
    }
}
