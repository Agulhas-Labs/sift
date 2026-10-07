//
// Copyright © Agulhas Labs
//

import Foundation

/// Which of several indexed roots are actually the same repository.
///
/// A linked worktree earns its place in the registry: it has its own working tree, its own branch and its own index, and a query against it is a real query. What it is *not* is a different project, and root resolution must not treat it as one. A checkout and an agent worktree inside it (`app` and `app/.claude/worktrees/<name>`) declare nearly every type in the repo between them, so a rootless `digest RecordListView` would come back "declared in 2 indexed roots — pass root: with the one you mean", which is a question with no useful answer: both roots are the same code. Names that happen to be unique to one side resolve normally, which is what makes it look intermittent rather than structural.
///
/// The rule is that ambiguity is only worth reporting *between repositories*. Within one, there is a right answer — the repository's own checkout — and picking it silently is what the caller wanted.
public struct RepositoryIdentity {
    /// One root per repository, preferring a repository's main working tree over any worktree linked to it.
    ///
    /// Order is preserved by first appearance so the result is stable, and roots git cannot answer for key as themselves, so anything outside a repository is never merged with anything else. `memo` lets a caller that already asked about some of these roots — `sameRepository`, typically — answer for them again without asking git twice; a call with nothing to share simply gets a memo of its own.
    public static func collapsingWorktrees(of roots: [String], memo: CallMemo = CallMemo()) -> [String] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for root in roots {
            let key = memo.identity(of: root)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(root)
        }
        return order.compactMap { grouped[$0].map { preferred(among: $0, memo: memo) } }
    }

    /// Whether two roots are the same repository — a checkout and one of its worktrees, or two worktrees of one repository.
    public static func sameRepository(_ one: String, _ other: String, memo: CallMemo = CallMemo()) -> Bool {
        memo.identity(of: one) == memo.identity(of: other)
    }

    /// The root that best represents a repository: its own checkout, or failing that the shortest path.
    ///
    /// The fallback matters when the checkout itself is not among the candidates — two worktrees of a repository whose main tree was never indexed. Choosing by length rather than by registry order keeps the answer the same whichever way the roots arrived.
    private static func preferred(among roots: [String], memo: CallMemo) -> String {
        if let checkout = roots.first(where: { isMainWorkingTree($0, memo: memo) }) {
            return checkout
        }
        return roots.min { ($0.count, $0) < ($1.count, $1) } ?? roots[0]
    }

    /// A repository's own checkout, as opposed to a worktree linked to it: the shared git directory is the one this tree keeps for itself.
    ///
    /// A linked worktree's private git directory sits under `worktrees/` inside the shared one, so the two differ exactly when the tree is a linked one. That holds where comparing the shared directory's *parent* to the root does not, because that comparison assumes the shared directory is `<checkout>/.git`: a `--separate-git-dir` checkout keeps it somewhere else entirely and would be read as a worktree of a repository with no checkout at all.
    ///
    /// **One input this answers `true` for and should not: a bare repository's own directory**, where `rev-parse` prints `.` for both and they compare equal. It is unreachable rather than handled, and the reason is worth writing down because it is a property of a *different* file: every root in the registry arrives through ``SiftEngine/init(directory:registry:)``, which resolves it with ``GitContext/discoverRoot(from:)`` — `rev-parse --show-toplevel`, which exits 128 inside a bare directory and yields `nil`. So no bare path can be recorded as a root, and nothing ever asks this about one. Anything that adds a second way to record a root has to keep that property or fix this: the failure would be a bare repository nominated as the checkout of the worktrees it holds, which is the one candidate that has no working tree to answer any query from.
    ///
    /// Reads through `memo`, the same one `collapsingWorktrees` used to group `root` with its siblings in the first place: the `rev-parse --git-dir --git-common-dir` that answered that question already carries both directories, so this asks nothing new of git.
    private static func isMainWorkingTree(_ root: String, memo: CallMemo) -> Bool {
        guard let pair = memo.directories(of: root) else { return false }
        return pair.own == pair.common
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

public extension RepositoryIdentity {
    /// A root path → identity memo scoped to a single caller's work, so its repeated questions about the same root spawn `git` at most once while an answer for it is known — a failure asks again on every retry, since a failed answer is never remembered as if it were one.
    ///
    /// `siblingPointers` is the caller this exists for: it asks whether each of several registered roots is `own`'s own repository, then asks `collapsingWorktrees` the very same question again for whichever of them declare or extend the target — the same root resolved twice, on every miss a session sees. Sharing one memo across both questions removes the second spawn. `preferred(among:)`'s own `rev-parse`, for whichever of those roots turns out to share an identity, is folded into the same cache: one `rev-parse --git-dir --git-common-dir` per root answers both what it is and whether it is its repository's main working tree.
    ///
    /// It goes no further than that one caller's work: nothing here is shared between calls, and a root's identity is never assumed to outlive the moment it was asked, because it can change under a path that keeps its name — a worktree removed and re-created elsewhere is the same path answering for a different repository. A memo kept across calls would have to notice that; one that dies with the call it was made for does not have to.
    final class CallMemo {
        private var pairs: [String: (own: String, common: String)] = [:]
        /// How many times this memo actually asked git, rather than answering from what it already held.
        ///
        /// Production code never reads this — it exists only so a test can show the sharing pays for itself.
        private(set) var rawResolutions = 0

        public init() {}

        fileprivate func identity(of root: String) -> String {
            directories(of: root)?.common ?? RepositoryIdentity.canonical(root)
        }

        /// Both of a root's git directories, resolved at most once and remembered only on success: a failure is never cached, because the same path can start — or stop — answering for a repository while this memo is still in use.
        fileprivate func directories(of root: String) -> (own: String, common: String)? {
            if let cached = pairs[root] {
                return cached
            }
            rawResolutions += 1
            guard let found = GitContext.directories(of: URL(fileURLWithPath: root)) else {
                return nil
            }
            let resolved = (own: found.own.path, common: found.common.path)
            pairs[root] = resolved
            return resolved
        }
    }
}
