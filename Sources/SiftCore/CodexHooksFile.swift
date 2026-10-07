//
// Copyright © Agulhas Labs
//

import Foundation

/// The hooks this tool registers in Codex's `hooks.json`, and the merge that adds them to or takes them out of that file.
///
/// Codex's file is `{"hooks": {"<Event>": [{"matcher": …, "hooks": [{"type": "command", "command": …}, …]}, …]}}`: per event, groups of handlers. Codex speaks Claude Code's hook protocol, so each command is the plain `<binary> <subcommand>` with no `--agent` flag, and a handler is this tool's by the same rule as a Claude Code registration (``HookRegistration/isOurs(_:subcommand:)``), in whichever group it sits. Every foreign handler, group and key is carried through verbatim. Codex keys a hook's trust by its group's and handler's positions, so a new group is always appended after the foreign ones, never inserted ahead of them.
public struct CodexHooksFile {
    /// The file's name inside the Codex directory.
    public static var fileName: String {
        "hooks.json"
    }

    /// Every event this registers for, the subcommand it runs and the matcher its group carries, in the order an answer lists them.
    public static var hooks: [Hook] {
        [
            Hook(event: "SessionStart", subcommand: "session-start", matcher: nil),
            Hook(event: "PreToolUse", subcommand: "pre-tool-use", matcher: "*"),
            Hook(event: "PostToolUse", subcommand: "post-tool-use", matcher: "*"),
        ]
    }

    /// The command registered for `hook`: the binary, already shell-quoted where it needs to be, then the subcommand.
    public static func command(for hook: Hook, binaryWord: String) -> String {
        "\(binaryWord) \(hook.subcommand)"
    }

    /// Merges this tool's hooks into `data` (nil or empty meaning no file yet), repointing a handler of ours that names another binary and dropping any second one, and leaving everything else as it is.
    public static func apply(to data: Data?, binaryWord: String) throws -> CursorHooksFile.Change {
        var file = try CursorConfigJSON.parse(data, file: fileName, harness: harness)
        var events = try CursorConfigJSON.object(file["hooks"], key: "hooks", file: fileName, harness: harness)
        var changed = false
        var replaced: [String] = []
        for hook in hooks {
            let wanted = command(for: hook, binaryWord: binaryWord)
            var found = false
            var groups: [Any] = []
            for group in try CursorConfigJSON.array(events[hook.event], key: hook.event, file: fileName, harness: harness) {
                let pass = try handlers(of: group, event: hook.event) { handler in
                    guard let previous = handler["command"] as? String, HookRegistration.isOurs(previous, subcommand: hook.subcommand) else {
                        return .keep
                    }
                    // A second handler of ours runs the hook twice per event, so only the first survives.
                    guard !found else { return .drop }
                    found = true
                    guard previous != wanted else { return .keep }
                    if !replaced.contains(previous) {
                        replaced.append(previous)
                    }
                    var repointed = handler
                    repointed["command"] = wanted
                    return .replace(repointed)
                }
                changed = changed || pass.changed
                if let kept = pass.group {
                    groups.append(kept)
                }
            }
            if !found {
                var group: [String: Any] = ["hooks": [["type": "command", "command": wanted]]]
                group["matcher"] = hook.matcher
                groups.append(group)
                changed = true
            }
            events[hook.event] = groups
        }
        guard changed else {
            return CursorHooksFile.Change(data: data ?? Data(), changed: false, replaced: [], removed: [])
        }
        file["hooks"] = events
        return try CursorHooksFile.Change(data: CursorConfigJSON.encode(file), changed: true, replaced: replaced, removed: [])
    }

    /// Takes this tool's handlers out of `data`, dropping a group they leave empty, an event with no group left and the `hooks` object when nothing is left in it; every foreign handler, group and key stays.
    public static func remove(from data: Data?) throws -> CursorHooksFile.Change {
        var file = try CursorConfigJSON.parse(data, file: fileName, harness: harness)
        var events = try CursorConfigJSON.object(file["hooks"], key: "hooks", file: fileName, harness: harness)
        var removed: [String] = []
        for hook in hooks where events[hook.event] != nil {
            var groups: [Any] = []
            var changed = false
            for group in try CursorConfigJSON.array(events[hook.event], key: hook.event, file: fileName, harness: harness) {
                let pass = try handlers(of: group, event: hook.event) { handler in
                    guard let command = handler["command"] as? String, HookRegistration.isOurs(command, subcommand: hook.subcommand) else {
                        return .keep
                    }
                    removed.append("\(hook.event) — \(command)")
                    return .drop
                }
                changed = changed || pass.changed
                if let kept = pass.group {
                    groups.append(kept)
                }
            }
            guard changed else { continue }
            events[hook.event] = groups.isEmpty ? nil : groups
        }
        guard !removed.isEmpty else {
            return CursorHooksFile.Change(data: data ?? Data(), changed: false, replaced: [], removed: [])
        }
        file["hooks"] = events.isEmpty ? nil : events
        return try CursorHooksFile.Change(data: CursorConfigJSON.encode(file), changed: true, replaced: [], removed: removed)
    }

    /// The harness a refusal of the file's shape names.
    private static var harness: String {
        "Codex"
    }

    /// Runs `decide` over each handler in `group`: the group as it should be written (`nil` when a handler of ours was all it held) and whether it changed.
    ///
    /// Anything that is not a group of handlers is kept as it is.
    private static func handlers(of group: Any, event: String, _ decide: ([String: Any]) -> Verdict) throws -> (group: Any?, changed: Bool) {
        guard var object = group as? [String: Any], object["hooks"] != nil else { return (group, false) }
        let entries = try CursorConfigJSON.array(object["hooks"], key: event, file: fileName, harness: harness)
        var kept: [Any] = []
        var changed = false
        for entry in entries {
            guard let handler = entry as? [String: Any] else {
                kept.append(entry)
                continue
            }
            switch decide(handler) {
            case .keep:
                kept.append(entry)
                continue
            case .drop:
                changed = true
            case let .replace(repointed):
                kept.append(repointed)
                changed = true
            }
        }
        guard changed else { return (group, false) }
        guard !kept.isEmpty else { return (nil, true) }
        object["hooks"] = kept
        return (object, true)
    }
}

extension CodexHooksFile {
    /// What becomes of one handler.
    private enum Verdict {
        case keep
        case drop
        case replace([String: Any])
    }
}

public extension CodexHooksFile {
    /// One Codex hook event, the subcommand it runs and its group's matcher.
    struct Hook: Equatable, Sendable {
        /// Codex's name for the event, the key in `hooks.json`.
        public let event: String
        /// The subcommand the handler runs, which is also what ownership is judged on.
        public let subcommand: String
        /// The group's `matcher`, or `nil` for an event that takes none.
        public let matcher: String?
    }
}
