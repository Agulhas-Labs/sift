//
// Copyright © Agulhas Labs
//

import Foundation

/// A Codex `apply_patch` call, which reaches the Claude Code registration's `post-tool-use` with its edit in Codex's own patch grammar, read as the Claude Code `Write` payloads the hook judges: one for each file the patch left to check.
///
/// Only the `*** Add File:` section's shape is from a captured payload; `*** Update File:`, `*** Delete File:` and `*** Move to:` are read as Codex's patch grammar documents them. A deleted file leaves nothing to check, and a moved one, like a patch whose exit code is not 0, is not read until a payload of it has been captured.
struct CodexApplyPatch {
    /// The Claude Code payloads `payload` stands for, in the order the patch names their files, or `nil` where it is not a `PostToolUse` payload of an `apply_patch` that exited 0.
    ///
    /// An added file is a `Write` that created it, so its prior is empty; an updated one is a `Write` whose prior is unknown, since an update's hunks carry no line numbers. Every other field is carried over, so the path still resolves against the payload's `cwd` and the session is the payload's.
    static func claudePayloads(from payload: [String: Any]) -> [[String: Any]]? {
        guard payload["hook_event_name"] as? String == "PostToolUse",
              payload["tool_name"] as? String == "apply_patch",
              let patch = (payload["tool_input"] as? [String: Any])?["command"] as? String,
              let response = payload["tool_response"] as? String
        else {
            return nil
        }
        guard response.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first == "Exit code: 0" else { return nil }
        return sections(in: patch).compactMap { section in
            guard !section.moved, section.kind != .delete else { return nil }
            var claude = payload
            claude["tool_name"] = "Write"
            claude["tool_input"] = ["file_path": section.path]
            claude.removeValue(forKey: "tool_response")
            if section.kind == .add {
                claude["tool_response"] = ["type": "create"]
            }
            return claude
        }
    }

    /// Every file section of `patch`, in order: a header line starts `*** `, where a line of a file's content starts `+`, `-`, a space or `@@`.
    static func sections(in patch: String) -> [Section] {
        var sections: [Section] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if let (kind, path) = header(line) {
                sections.append(Section(kind: kind, path: path))
            } else if line.hasPrefix("*** Move to: "), !sections.isEmpty {
                sections[sections.count - 1].moved = true
            }
        }
        return sections
    }

    private static let headers: [(prefix: String, kind: Kind)] = [
        ("*** Add File: ", .add),
        ("*** Update File: ", .update),
        ("*** Delete File: ", .delete),
    ]

    /// The section `line` opens, with the path it names, or `nil` where it opens none.
    private static func header(_ line: Substring) -> (Kind, String)? {
        for (prefix, kind) in headers where line.hasPrefix(prefix) {
            return (kind, String(line.dropFirst(prefix.count)))
        }
        return nil
    }
}

extension CodexApplyPatch {
    enum Kind {
        case add
        case update
        case delete
    }

    /// One file's section of a patch: what it does to the file, the path as the patch names it, and whether it moves the file.
    struct Section: Equatable {
        let kind: Kind
        let path: String
        var moved = false
    }
}
