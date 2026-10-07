//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The state of the indexes an audit's lookups ran against, and the names the audit and the report give their roots.
struct AuditModuleHealth {
    /// The state of the indexes those lookups ran against — the half of "is this helping" a share cannot see.
    ///
    /// A guessed module is the failure that does not show up in any count here: the answers still arrive, on time, and are about a module that does not exist. It is invisible from the transcript side, and it is exactly what a build system whose manifests the resolver cannot read produces — so a low share on an unfamiliar repo has two very different explanations, and this is the line that tells them apart.
    ///
    /// Read strictly read-only, and silent when there is nothing to say: an audit is run to see the misses, and a clean bill of module health is not worth a line of anyone's screen.
    ///
    /// Reported only where guessing is the *rule* rather than the exception. Most repos have a handful of loose files outside any manifest — scripts, plugins, a `Package.swift` — and listing a couple of files in every root would bury the case this exists for, which is a repo where nothing resolves at all.
    static func indexHealth(roots: [String], redactor: Redactor?) -> [String] {
        moduleHealth(roots.compactMap { root in
            ReadOnlyIndex.snapshot(atRoot: root).map { (root: root, snapshot: $0) }
        }, redactor: redactor)
    }

    /// The module-resolution lines for already-read snapshots — the decision, separated from the disk it came off so it can be pinned without standing up several indexed repositories.
    ///
    /// A root qualifies only when guessing is at least a tenth of it. Most repos have a handful of loose files outside any manifest (a `Package.swift`, a plugin, a script), and listing a couple of files in every root would bury the case this exists for: a repo where nothing resolves at all.
    static func moduleHealth(_ snapshots: [(root: String, snapshot: ReadOnlyIndex.Snapshot)], redactor: Redactor? = nil) -> [String] {
        // The threshold is the primer's, called rather than restated: the two surfaces warning about the
        // same condition disagreeing about when it holds is a worse bug than either warning being wrong.
        let guessing = snapshots
            .filter { SessionPrimer.ModuleHealth(guessed: $0.snapshot.guessedModules, files: $0.snapshot.files).isMostlyGuessed }
            .sorted { $0.snapshot.guessedModules > $1.snapshot.guessedModules }
        guard !guessing.isEmpty else { return [] }

        var lines = ["", "module resolution — roots where a module is mostly inferred from a directory name, not read from a manifest:"]
        for (root, snapshot) in guessing.prefix(10) {
            let share = snapshot.guessedModules * 100 / snapshot.files
            // Not led by `sift init`: SwiftPM, XcodeGen and `.xcodeproj` are all read automatically, so a root
            // still guessing after an upgrade is either running an older binary or built by something none of
            // those describe — and the first of those is the likelier and the cheaper to check.
            let rootName = redactor?.root(root) ?? name(root, among: guessing.map(\.root))
            lines.append("  \(TranscriptAudit.pad(share))% \(rootName) — \(snapshot.guessedModules) of \(snapshot.files) files; upgrade first (SwiftPM, XcodeGen and .xcodeproj all resolve on their own now, and an upgraded binary re-attributes without being asked), then `sift init` there if it persists")
        }
        lines.append("  (answers from those files arrive on time and name a module that does not exist — invisible in every count above)")
        return lines
    }

    /// A root's shortest unambiguous name among `peers` — its own directory, or its parent's too when several share it.
    ///
    /// Several roots on one machine can be called `app` — one per product folder — so the bare name would silently merge them into one line about the wrong repository.
    static func name(_ root: String, among peers: [String]) -> String {
        let url = URL(fileURLWithPath: root)
        let base = url.lastPathComponent
        guard peers.filter({ URL(fileURLWithPath: $0).lastPathComponent == base }).count > 1 else { return base }
        return url.deletingLastPathComponent().lastPathComponent + "/" + base
    }
}
