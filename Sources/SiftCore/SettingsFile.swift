//
// Copyright © Agulhas Labs
//

import Foundation

/// The Claude Code settings file `install-hook`, `uninstall-hook` and `uninstall` rewrite: one writer for all three, so a `settings.json` that is a symlink stays one and the file it leads to is the one that changes.
///
/// A settings file kept in a dotfiles repository and linked into `~/.claude` is a deliberate arrangement, so the link is written through rather than replaced by a copy that would leave the dotfiles file still holding what the answer says was removed. The backup goes beside the file that changed, and a link that leads nowhere is refused before anything is written.
public struct SettingsFile {
    /// The file a rewrite of `settings` lands in: `settings` itself unless it is a symlink, and otherwise the file at the end of its chain of links.
    public static func target(of settings: URL) throws -> URL {
        guard case let .symlink(destination) = PathKind.of(settings) else { return settings }
        guard let resolved = realpath(settings.path, nil) else {
            let reason = switch errno {
            case ELOOP:
                "a symlink in a loop of links"
            case ENOENT, ENOTDIR:
                "a symlink to \(destination ?? "an unreadable target"), which leads to nothing"
            default:
                "a symlink to \(destination ?? "an unreadable target"), which could not be followed: \(String(cString: strerror(errno)))"
            }
            throw Unresolved(path: settings.path, reason: reason)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Replaces the file `settings` leads to with `data`, atomically, after keeping `original` beside it, returning why that copy was not kept or `nil` when it was or there was nothing to keep.
    ///
    /// The link, where `settings` is one, is left as it is; a link that leads nowhere throws before the backup or the write, and a write that fails throws ``Unwritten`` naming both paths.
    public static func rewrite(_ settings: URL, with data: Data, original: Data?) throws -> String? {
        let target = try target(of: settings)
        let backupNote = SettingsBackupFile.write(original, beside: target)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw Unwritten(path: named(settings), reason: error.localizedDescription)
        }
        return backupNote
    }

    /// `settings` as an answer names it: its path, followed by the file it leads to when it is a symlink.
    public static func named(_ settings: URL) -> String {
        guard let target = try? target(of: settings), target != settings else { return settings.path }
        return "\(settings.path) → \(target.path)"
    }
}

public extension SettingsFile {
    /// A settings path that is a symlink leading nowhere — to nothing, or around a loop — so there is no file to rewrite and nothing is written through it.
    struct Unresolved: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String

        public var description: String {
            "\(path) is \(reason); nothing is written through it — repair the link, or point --settings at the file itself"
        }
    }

    /// A rewrite that did not land — the directory the file is in cannot be written, say — so the file holds what it held before.
    struct Unwritten: Error, CustomStringConvertible, Sendable {
        /// The settings path as an answer names it, with the file it leads to when it is a symlink.
        public let path: String
        public let reason: String

        public var description: String {
            "\(path) could not be rewritten: \(reason)"
        }
    }
}
