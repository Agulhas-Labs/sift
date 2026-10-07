//
// Copyright © Agulhas Labs
//

import Foundation

/// Recognises and removes this tool's status-line command in a Claude Code `settings.json`, as a pure transform over the file's bytes.
///
/// Sift no longer registers a status line; an older install's is taken out by `install-hook` and the uninstall. `statusLine` is a **single slot**, so only a command of this tool's shape is ever removed: a status line someone built is theirs and stays.
public struct StatuslineRegistration {
    /// Empties the status-line slot, but only if this tool is what is in it.
    ///
    /// The single slot cuts the same way on the way out as on the way in: an uninstall that cleared it unconditionally would delete a status line someone built, which is worse than leaving one of ours behind. So the recognition test is `isOurs` and nothing else — a slot holding something unrecognised is reported, never emptied.
    public static func remove(from data: Data?) throws -> Removal {
        var settings = try parse(data)
        guard let value = settings["statusLine"] else { return .absent }
        guard let existing = value as? [String: Any] else {
            return .notOurs(existing: "(a status line of an unrecognised shape)")
        }
        let command = existing["command"] as? String
        guard let command, isOurs(command) else {
            return .notOurs(existing: command ?? "(a status line of an unrecognised shape)")
        }

        settings.removeValue(forKey: "statusLine")
        let encoded = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return .removed(encoded, command: command)
    }

    /// Whether a configured status-line command is ours, at any path.
    ///
    /// Matched by shape rather than exact path for the same reason the hook is: a re-run after the binary moves must replace the old registration, not sit beside a stale one. The shape is the hook's exact one (``SiftPaths/runsThisTool(_:subcommand:)``), so a status line someone else built at a path containing the name is refused, never taken.
    public static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return SiftPaths.runsThisTool(command, subcommand: "statusline")
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookRegistrationError.settingsNotAnObject
        }
        return object
    }
}

public extension StatuslineRegistration {
    /// What the removal did, so the uninstaller can report it rather than claim success blandly.
    enum Removal: Equatable, Sendable {
        case removed(Data, command: String)
        /// No status line was configured at all — nothing to undo.
        case absent
        /// Something this tool did not register is in the slot, and an uninstall will not take it either.
        case notOurs(existing: String)
    }
}
