//
// Copyright © Agulhas Labs
//

import Foundation

/// The uninstall's `.sift/` step: each directory the tool left, deleted under `purge` and listed otherwise, never deleted through a link or when it is not a directory.
struct UninstallPurge {
    /// The directories deleted and confirmed gone.
    var purged: [String] = []
    /// The directories listed and kept, without `purge`.
    var left: [String] = []
    /// What it refused or could not delete, and why.
    var notes: [String] = []
    /// How many of the directories it was asked to delete are still there.
    var failures = 0
    /// The recorded repositories no record names once the purge is done, so a later run will not look in them.
    var unrecorded: [String] = []

    /// Deletes each of `caches` under `purge`, a repository's through the set-aside lock and `~/.sift` outright, and reads each path again so it is reported purged only once it is gone.
    static func settle(_ caches: [SiftUninstall.LeftCache], purge: Bool) -> UninstallPurge {
        var step = UninstallPurge()
        for cache in caches {
            if let refusal = cache.refusal {
                // Never followed: a delete through the link would empty a directory this tool did not make.
                if purge {
                    step.failures += 1
                    step.notes.append("not purged: \(cache.directory.path) is \(refusal)")
                } else {
                    step.notes.append("left: \(cache.directory.path) is \(refusal)")
                }
                continue
            }
            guard purge else {
                step.left.append(cache.directory.path)
                continue
            }
            do {
                if let root = cache.repository {
                    try SetAsideSession.clearCache(in: root)
                } else {
                    try FileManager.default.removeItem(at: cache.directory)
                }
            } catch {
                step.failures += 1
                step.notes.append("not purged: \(cache.directory.path) — \(error)")
                continue
            }
            if FileManager.default.fileExists(atPath: cache.directory.path) {
                step.failures += 1
                step.notes.append("not purged: \(cache.directory.path) — still there after the delete")
            } else {
                step.purged.append(cache.directory.path)
            }
        }
        return step
    }

    /// What a purge leaves that a later run cannot see: the recorded repositories whose record went with `~/.sift`, and `~/.sift` itself when it is there again at the end, which is not counted purged.
    mutating func settleAftermath(_ locations: SiftUninstall.Locations, roots: [String]) {
        let home = locations.siftHome.path
        if purged.contains(home) {
            if PathKind.of(locations.siftHome) != .absent {
                purged.removeAll { $0 == home }
                failures += 1
                notes.append("not purged: \(home) — there again at the end of the uninstall, so something still running recreated it")
            }
            notes.append("sessions: any already running keep the hooks and MCP server they started with, and can recreate \(home) until they end")
        }
        let still = Set(SiftUninstall.recordedRoots(locations).roots)
        unrecorded = roots.filter { !still.contains($0) }
    }
}
