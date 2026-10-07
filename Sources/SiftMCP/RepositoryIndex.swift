//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether a looked-up path stands in a repository the call a refusal offers could be rooted at.
///
/// **A refusal has to offer a call that can be made**, and that is the one claim about a *tree* the hook still makes. It used to make a second — *no index, no nudge*, an unindexed repository drawing nothing on the argument that the offered call would have to index a whole checkout before it could say a word. That was measured wrong (`Docs/Design.md`): indexing from nothing costs tenths of a second, and the rule silenced the hook for every isolated subagent, each of which runs in a `.claude/worktrees/<agent>/` nothing has ever indexed. A repository with no index now answers like any other, and whatever answers — the in-place answerer, or the `digest` a plain refusal names — builds the index it needs.
///
/// **A path with no repository above it at all is the case that remains**, because no amount of indexing gives it a root. A call naming a *path* is answered by reading that exact path under a root; a scratch tree or a fixture in a temporary directory resolves none, so the refusal would deny the read and then charge a whole context re-send to ask for it back.
public struct RepositoryIndex {
    /// Whether `path` stands outside every repository — the tree where the call a refusal offers has no root to be answered at.
    ///
    /// The claim is that there is no repository, so the call resolves no root at all and answers `… is in no repository to root at — read it directly` (`DigestRenderer.markdownMiss`) — which is the read the refusal just denied, charged a whole context re-send to arrive at. A refusal has to offer a call that can be made, and that invariant is about the call rather than about any one subject: a whole read of Swift source outside every repository is the same dead end, rarely as it happens.
    ///
    /// The everyday case is a document. A `.md` target is named by its own path and read live under a root (``SiftMCP/ReadAdvice``), and the Markdown a context reads whole is as often outside a checkout as in one — a vault note, a rule file under `~/.claude`, a plan written in a home directory. `/tmp` escapes by an earlier rule (``SwiftTree/isOutsideIndexedSources(_:relativeTo:)``) and nothing else did.
    ///
    /// Walks up from `path` — taken as a starting point rather than as a file, and resolved against `directory`, the call's own working directory, because the hook's process runs wherever the harness started it and never where the caller stands. The `.git` test is existence rather than kind, since a linked worktree carries it as a file, and the walk stops at the first repository boundary, which answers `false`, or at the filesystem root, which answers `true`. A path that resolves against no directory answers `false`: nothing was named that could be judged.
    public static func isRootless(for path: String, relativeTo directory: String? = nil) -> Bool {
        guard let resolved = SwiftTree.resolve(path, relativeTo: directory) else { return false }
        let manager = FileManager.default
        var current = URL(fileURLWithPath: resolved).standardizedFileURL
        while true {
            if manager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return false
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { return true }
            current = parent
        }
    }
}
