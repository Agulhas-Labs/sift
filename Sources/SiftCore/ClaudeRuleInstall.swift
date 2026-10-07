//
// Copyright © Agulhas Labs
//

import Foundation

/// The agent rule half of the Claude Code install: copies the `Sift.md` that ships beside the binary to the rule path, as `install.sh` does.
///
/// A symlink at the rule path is left alone, since it means the rule is a checkout's own file; a rule that differs is kept as `sift.md.bak-sift` before it is replaced.
public struct ClaudeRuleInstall {
    /// The `Sift.md` that ships with the binary at `binary`: beside the file its links lead to (the release bundle), else in `../share/sift` from there (Homebrew's `pkgshare`), else `nil`.
    public static func source(forBinary binary: String) -> URL? {
        let directory = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("Sift.md"),
            directory.deletingLastPathComponent().appendingPathComponent("share/sift/Sift.md"),
        ]
        return candidates.first { PathKind.of($0.resolvingSymlinksInPath()) == .file }
    }

    /// Reads what an install of `source` at `destination` would do; writes nothing.
    public static func plan(source: URL?, destination: URL) -> Plan {
        guard let source else { return .noSource }
        return switch PathKind.of(destination) {
        case .absent:
            .copy
        case let .symlink(target):
            .symlink(target ?? "an unreadable target")
        case .file:
            (try? Data(contentsOf: destination)) == (try? Data(contentsOf: source)) ? .identical : .replace
        case .directory, .other:
            .refused
        }
    }

    /// Copies `source` to `destination` as ``plan(source:destination:)`` says, keeping a differing rule beside it first.
    public static func install(source: URL?, destination: URL) throws -> CursorInstall.Outcome {
        var outcome = CursorInstall.Outcome(lines: [], notes: [], written: [])
        let path = destination.path
        switch plan(source: source, destination: destination) {
        case .noSource:
            outcome.notes.append("rule: skipped — no Sift.md ships with this binary (the release bundle and Homebrew carry it)")
        case .identical:
            outcome.lines.append("rule: already installed — \(path)")
        case let .symlink(target):
            outcome.lines.append("rule: \(path) is a symlink to \(target) — left as is")
        case .refused:
            outcome.failures.append("rule: not written — \(path) is not a plain file")
        case .copy, .replace:
            guard let source else { return outcome }
            let data = try Data(contentsOf: source)
            let original = try? Data(contentsOf: destination)
            if let backupNote = SettingsBackupFile.write(original, beside: destination) {
                outcome.failures.append("rule: not replaced — \(backupNote)")
                return outcome
            }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch {
                outcome.failures.append("rule: not written — \(path): \(error.localizedDescription)")
                return outcome
            }
            let kept = original == nil ? "" : " (the previous one kept as \(SettingsBackupFile.url(beside: destination).path))"
            outcome.lines.append("rule: installed \(path) (loads on **/*.swift)\(kept)")
            outcome.written.append(path)
        }
        return outcome
    }
}

public extension ClaudeRuleInstall {
    /// What an install would do at the rule path.
    enum Plan: Equatable, Sendable {
        /// No `Sift.md` ships with this binary, so there is nothing to copy.
        case noSource
        /// Nothing is at the rule path.
        case copy
        /// The rule path already holds these bytes.
        case identical
        /// The rule path is a symlink, to this target.
        case symlink(String)
        /// The rule path holds something else, which is kept beside it before it is replaced.
        case replace
        /// The rule path is not a plain file or a symlink.
        case refused
    }
}
