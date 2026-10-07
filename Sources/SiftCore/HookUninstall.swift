//
// Copyright © Agulhas Labs
//

import Foundation

/// Takes this tool's hooks, allow rules and status line back out of a Claude Code settings file: the whole of `uninstall-hook`, and the first step of `uninstall`.
///
/// Everything the install refused to touch on the way in is refused on the way out too — a foreign hook in the same event, a status line someone built themselves. A settings file that is not there registered nothing, which is the answer rather than an error, and the write never runs, so an uninstall never creates the file it came to clean.
public struct HookUninstall {
    /// Removes the registrations from the file at `settings`, or the file it leads to when it is a symlink, rewriting that atomically after a backup when anything came out.
    ///
    /// `onlyAdvice` narrows the removal to the `PreToolUse` shell hook and its allow rules, keeping the session primer and the status line.
    public static func run(settings: URL, onlyAdvice: Bool) throws -> Outcome {
        // Only a path with nothing at it registered nothing: a file that is there and cannot be read was never checked, and
        // neither was a link that leads nowhere.
        do {
            _ = try SettingsFile.target(of: settings)
        } catch let unresolved as SettingsFile.Unresolved {
            throw Unreadable(path: settings.path, reason: unresolved.reason)
        }
        var original: Data?
        if PathKind.of(settings) != .absent {
            do {
                original = try Data(contentsOf: settings)
            } catch {
                throw Unreadable(path: settings.path, reason: error.localizedDescription)
            }
        }
        var current = original ?? Data()

        var removed: [String] = []
        for event in HookRegistration.eventsToRemove(onlyAdvice: onlyAdvice) {
            let removal = try HookRegistration.remove(from: current, event: event.name, subcommand: event.subcommand)
            guard !removal.removed.isEmpty else { continue }
            current = removal.data
            for command in removal.removed {
                removed.append("hook: removed \(event.name) — \(command)")
            }
        }

        // The allow rules go with the PreToolUse hook whose rewrite they exist for, so `onlyAdvice` takes them too.
        // Only the last contiguous block of the set install writes is recognised as its own; a rule the user wrote stays,
        // and so does a `permissions` of a shape install would not have written.
        if let updated = try? RunAllowRules.removing(from: current) {
            current = updated
            removed.append("permissions: removed \(RunAllowRules.rules.joined(separator: ", "))")
        }
        if let updated = try? LookupAllowRules.removing(from: current) {
            current = updated
            removed.append("permissions: removed \(LookupAllowRules.rules.joined(separator: ", "))")
        }

        var statusline: String?
        // `onlyAdvice` is the whole point of leaving this alone: the status line is the half of the install that costs
        // nothing per tool call and is the last thing someone tiring of nudges means.
        if !onlyAdvice {
            switch try StatuslineRegistration.remove(from: current) {
            case let .removed(updated, command):
                current = updated
                removed.append("statusline: removed — \(command)")
            case .absent:
                statusline = "statusline: nothing registered"
            case let .notOurs(existing):
                statusline = "statusline: not ours, left alone (\(existing))"
            }
        }

        guard !removed.isEmpty else {
            return Outcome(removed: [], statusline: statusline, backupNote: nil)
        }

        // Backed up before the rewrite for the same reason the install does it: this is the user's whole Claude Code
        // configuration and this tool did not author it.
        // Nothing to forget elsewhere: what is registered is read back out of this file (`RegisteredHooks`), so taking the
        // registration out of it is the record being cleared.
        let backupNote = try SettingsFile.rewrite(settings, with: current, original: original)
        return Outcome(removed: removed, statusline: statusline, backupNote: backupNote)
    }
}

public extension HookUninstall {
    /// A settings file that is there and could not be read — its permissions, a directory at the path, a dangling link — so whether it registers anything is not known.
    struct Unreadable: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String

        public var description: String {
            "hooks: not checked — \(path) could not be read: \(reason)"
        }
    }

    /// What one run took out, and what it found in the status-line slot.
    struct Outcome: Equatable, Sendable {
        /// One line per registration taken out, in the order they went: hooks, then allow rules, then the status line.
        public let removed: [String]

        /// What was in the status-line slot when it was not taken out — nothing of ours, or someone else's — or `nil` when the slot was not in scope.
        public let statusline: String?

        /// Why the copy of the file as it was before the rewrite was not kept, or `nil` when it was or nothing was rewritten.
        public let backupNote: String?

        /// Whether the settings file was rewritten — with a copy of the previous one kept beside it unless `backupNote` says why not.
        public var changed: Bool {
            !removed.isEmpty
        }
    }
}
