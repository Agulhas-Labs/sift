//
// Copyright © Agulhas Labs
//

import Foundation

public extension ShellGrep {
    /// The program a harness's shell runs for `grep`, which decides what a recursive walk passes over before any file is read.
    ///
    /// Claude Code's shell defines `grep` as a function running its own `ugrep` with `-G --ignore-files --hidden -I` and an `--exclude-dir` for each of ``UgrepSkips/versionControlDirectories``. Neither Cursor nor Codex ships `ugrep` or wraps `grep`, so their shells run the system's own, which descends into every directory and reports a match in a binary file rather than skipping it.
    enum Program: Sendable {
        /// Claude Code's `ugrep`.
        case ugrep
        /// The system's own `grep`, in any shell that does not wrap it.
        case system

        /// The program of the shell whose command the hook in progress answers, bound by the hook for the harness that called it; Claude Code's where nothing bound one.
        ///
        /// Work handed to a detached task has to carry it across itself.
        @TaskLocal public static var current: Program = .ugrep

        /// The directory names a recursive walk never descends into.
        var skippedDirectories: Set<String> {
            switch self {
            case .ugrep: UgrepSkips.versionControlDirectories
            case .system: []
            }
        }

        /// Which ignore files a recursive walk honours: `ugrep --ignore-files` reads those it meets at or below the directory it searches.
        var ignoreScope: IgnoreScope {
            self == .ugrep ? .belowOnly : .none
        }
    }
}
