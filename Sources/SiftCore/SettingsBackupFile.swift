//
// Copyright © Agulhas Labs
//

import Foundation

/// The copy of a Claude Code settings file that `install-hook`, `uninstall-hook` and `uninstall` keep beside it before each rewrite, `settings.json.bak-sift`, beside the file a symlinked settings path leads to: one writer for all three, so none of them writes through a link at the backup's own path.
public struct SettingsBackupFile {
    /// Where the copy of `settings` goes.
    public static func url(beside settings: URL) -> URL {
        settings.appendingPathExtension("bak-sift")
    }

    /// Keeps `original` beside `settings`, returning `nil` when it was written or there was nothing to keep, and otherwise the line that says why it was not.
    ///
    /// Only a missing path or a plain file is written, and atomically, so the copy replaces what was there rather than writing into it. A symlink, a directory or anything else at the path is left as it is and named: the file a link points to is not one this tool made.
    public static func write(_ original: Data?, beside settings: URL) -> String? {
        guard let original, !original.isEmpty else { return nil }
        let backup = url(beside: settings)
        let reason: String
        switch PathKind.of(backup) {
        case .absent, .file:
            do {
                try original.write(to: backup, options: .atomic)
            } catch {
                return "backup: not written — \(backup.path): \(error.localizedDescription)"
            }
            return nil
        case let .symlink(target):
            reason = "a symlink to \(target ?? "an unreadable target"), not a file"
        case .directory, .other:
            reason = "not a plain file"
        }
        return "backup: not written — \(backup.path) is \(reason), and nothing is written through it"
    }
}
