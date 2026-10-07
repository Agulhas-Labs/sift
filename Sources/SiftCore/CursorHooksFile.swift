//
// Copyright © Agulhas Labs
//

import Foundation

/// The hooks this tool registers in Cursor's `~/.cursor/hooks.json`, and the merge that adds them to or takes them out of that file.
///
/// Cursor's file is `{"version": 1, "hooks": {"<event>": [{"command": …}, …]}}`: one flat array of entries per event, each entry one command run through a shell. An entry is this tool's only when its command is an executable named `sift` running the event's subcommand with `--agent cursor` and nothing else (``HookRegistration/isOurs(_:subcommand:)``), so a foreign entry in the same array, and every key this tool does not write, is carried through verbatim. Each entry carries only `command`, the shape a live Cursor was seen to run; Cursor's fail-closed flag is never written, since a hook that fails must never make a call unavailable.
public struct CursorHooksFile {
    /// The file's name inside the Cursor directory.
    public static var fileName: String {
        "hooks.json"
    }

    /// The flag every registered command carries, so the handler answers in Cursor's protocol rather than guessing it from the payload.
    public static var agentFlag: String {
        "--agent cursor"
    }

    /// Every event this registers for and the subcommand it runs, in the order an answer lists them.
    public static var hooks: [Hook] {
        [
            Hook(event: "sessionStart", subcommand: "session-start"),
            Hook(event: "preToolUse", subcommand: "pre-tool-use"),
            Hook(event: "postToolUse", subcommand: "post-tool-use"),
        ]
    }

    /// The command registered for `hook`: the binary, already shell-quoted where it needs to be, then the subcommand and the flag.
    public static func command(for hook: Hook, binaryWord: String) -> String {
        "\(binaryWord) \(hook.registeredSubcommand)"
    }

    /// Merges this tool's hooks into `data` (nil or empty meaning no file yet), repointing an entry of ours that names another binary and dropping any second one, and leaving everything else as it is.
    public static func apply(to data: Data?, binaryWord: String) throws -> Change {
        var file = try CursorConfigJSON.parse(data, file: fileName)
        var events = try CursorConfigJSON.object(file["hooks"], key: "hooks", file: fileName)
        var changed = false
        var replaced: [String] = []
        for hook in hooks {
            let wanted = command(for: hook, binaryWord: binaryWord)
            var entries = try CursorConfigJSON.array(events[hook.event], key: hook.event, file: fileName)
            var kept: [Any] = []
            var found = false
            for element in entries {
                guard var entry = element as? [String: Any],
                      let previous = entry["command"] as? String,
                      HookRegistration.isOurs(previous, subcommand: hook.registeredSubcommand)
                else {
                    kept.append(element)
                    continue
                }
                // A second entry of ours runs the handler twice per event, so only the first survives.
                guard !found else {
                    changed = true
                    continue
                }
                found = true
                if previous != wanted {
                    entry["command"] = wanted
                    changed = true
                    if !replaced.contains(previous) {
                        replaced.append(previous)
                    }
                }
                kept.append(entry)
            }
            if !found {
                kept.append(["command": wanted])
                changed = true
            }
            entries = kept
            events[hook.event] = entries
        }
        guard changed else {
            return Change(data: data ?? Data(), changed: false, replaced: [], removed: [])
        }
        file["hooks"] = events
        if file["version"] == nil {
            file["version"] = 1
        }
        return try Change(data: CursorConfigJSON.encode(file), changed: true, replaced: replaced, removed: [])
    }

    /// Takes this tool's hooks out of `data`, dropping an event array it leaves empty and the `hooks` object when nothing is left in it; every foreign entry and key stays, `version` included.
    public static func remove(from data: Data?) throws -> Change {
        var file = try CursorConfigJSON.parse(data, file: fileName)
        var events = try CursorConfigJSON.object(file["hooks"], key: "hooks", file: fileName)
        var removed: [String] = []
        for hook in hooks {
            guard events[hook.event] != nil else { continue }
            let entries = try CursorConfigJSON.array(events[hook.event], key: hook.event, file: fileName)
            var kept: [Any] = []
            for element in entries {
                guard let entry = element as? [String: Any],
                      let command = entry["command"] as? String,
                      HookRegistration.isOurs(command, subcommand: hook.registeredSubcommand)
                else {
                    kept.append(element)
                    continue
                }
                removed.append("\(hook.event) — \(command)")
            }
            guard kept.count != entries.count else { continue }
            events[hook.event] = kept.isEmpty ? nil : kept
        }
        guard !removed.isEmpty else {
            return Change(data: data ?? Data(), changed: false, replaced: [], removed: [])
        }
        file["hooks"] = events.isEmpty ? nil : events
        return try Change(data: CursorConfigJSON.encode(file), changed: true, replaced: [], removed: removed)
    }
}

public extension CursorHooksFile {
    /// One Cursor hook event and the subcommand it runs.
    struct Hook: Equatable, Sendable {
        /// Cursor's name for the event, the key in `hooks.json`.
        public let event: String
        /// The subcommand the handler runs, without the flag.
        public let subcommand: String

        /// The subcommand as registered: with the flag, which is also what ownership is judged on.
        public var registeredSubcommand: String {
            "\(subcommand) \(CursorHooksFile.agentFlag)"
        }
    }

    /// What a merge did to the file.
    struct Change: Equatable, Sendable {
        /// The file as it should be written; the input unchanged when ``changed`` is false.
        public let data: Data
        /// Whether ``data`` differs from what was read.
        public let changed: Bool
        /// The commands of ours that named another binary and were repointed, each once.
        public let replaced: [String]
        /// One `<event> — <command>` per entry taken out.
        public let removed: [String]
    }
}
