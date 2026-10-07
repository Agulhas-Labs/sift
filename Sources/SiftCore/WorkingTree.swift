//
// Copyright © Agulhas Labs
//

import Foundation

/// Which checkout an answer was measured against, in a form that can be printed.
///
/// `Docs/AnswerContract.md` §1 says the header names the state the answer describes, and this is the axis of that state the others leave out: *which tree*. Without it a subagent sharing its parent's server has nothing to notice — a worktree and the checkout it was cut from share `head:`, hold the same symbol names and differ only in `dirty:`, which a reader has no baseline for, so two answers from two different trees would be byte-identical in the header.
///
/// The Wording rule keeps absolute paths out of answers meant to be shared, and it applies here more than anywhere: the header is the line that gets pasted. So this is the repository's name, plus the worktree's own name where the tree is a linked one — enough to tell two trees of one repository apart, and nothing that names the machine or its owner. A repository the tool cannot ask git about keeps its directory name, which is the honest answer when there is nothing else to say.
public struct WorkingTree: Sendable, Equatable {
    /// The repository's name — the same string from whichever of its trees the question is asked, wherever git can supply one.
    ///
    /// Usually the directory the main working tree sits in, because usually there is one and the shared git directory sits inside it. Two layouts have no such directory, and the name comes from the git directory itself: a **bare** repository (`orchard.git` is the repository `orchard`), and a repository whose git directory was placed outside its checkout with `--separate-git-dir`, where a *linked worktree* can only be told the git directory's name — see ``describing(_:)`` and ``repositoryName(sharing:)`` for why that last one is a limit of git rather than a choice made here.
    public let repository: String

    /// This linked worktree's own directory name, or `nil` when this *is* the repository's main working tree.
    public let worktree: String?

    public init(repository: String, worktree: String? = nil) {
        self.repository = repository
        self.worktree = worktree
    }

    /// The header's `tree:` field.
    ///
    /// The marker is a word rather than a symbol because the whole point is that it is read: `Sift (worktree agent-1a2b3c4d)` is a sentence, and a reader who has never seen this field before still knows what it is telling them.
    public var rendered: String {
        guard let worktree else { return repository }
        return "\(repository)\(Self.worktreeOpening)\(worktree))"
    }

    /// The name of the directory this tree is checked out in: a linked worktree's own, or for a main working tree the repository's, which ``describing(_:)`` takes from that directory.
    public var directoryName: String {
        worktree ?? repository
    }

    /// The tree a finished answer's header names, read back out of its `tree:` field; `nil` for an answer with no header near its top.
    ///
    /// Kept beside ``rendered`` so the wording and its reader cannot drift. A reader of a finished answer — the transcript scan — has no other record of which checkout answered, and the answer's paths are relative to it.
    public static func named(inAnswer answer: String) -> WorkingTree? {
        for line in answer.split(separator: "\n").prefix(SourcePassthrough.headerSearchDepth) where line.hasPrefix(fieldOpening) {
            let field = line.dropFirst(fieldOpening.count)
            let rendered = field.firstRange(of: fieldSeparator).map { field[..<$0.lowerBound] } ?? field
            guard rendered.hasSuffix(")"), let marker = rendered.range(of: worktreeOpening, options: .backwards) else {
                return rendered.isEmpty ? nil : WorkingTree(repository: String(rendered))
            }
            let worktree = rendered[marker.upperBound...].dropLast()
            let repository = rendered[..<marker.lowerBound]
            guard !repository.isEmpty, !worktree.isEmpty else { return nil }
            return WorkingTree(repository: String(repository), worktree: String(worktree))
        }
        return nil
    }

    /// How the header's field opens, written by ``Freshness`` and read back by the reader above.
    static var fieldOpening: String {
        "tree: "
    }

    /// What separates one header field from the next.
    static var fieldSeparator: String {
        "  "
    }

    private static var worktreeOpening: String {
        " (worktree "
    }

    /// The tree at `root`, named by asking git which repository it belongs to.
    ///
    /// Git is the *only* thing that can distinguish the two cases: a linked worktree's path says nothing about where it came from, and worktrees are routinely sited outside the repository they belong to. ``GitContext/directories(of:)`` answers it directly — a main working tree's own git directory *is* the common one, a linked worktree's sits under `worktrees/` inside it — which is the test that holds whatever shape the repository has.
    ///
    /// Resolved once per engine rather than once per answer. It spawns git, the header is built on every query, and a root does not move under an open engine.
    public static func describing(_ root: URL) -> WorkingTree {
        describing(root, directories: GitContext.directories(of: root))
    }

    /// The tree at `root`, named from the git directories the caller already asked git for.
    ///
    /// `directories` is ``GitContext/directories(of:)`` for `root`, `nil` where git had no answer, so an engine that needs the pair for more than the name spawns `rev-parse` once rather than once per use.
    public static func describing(_ root: URL, directories: (own: URL, common: URL)?) -> WorkingTree {
        let name = root.standardizedFileURL.lastPathComponent
        guard let directories else {
            return WorkingTree(repository: name)
        }
        guard directories.own != directories.common else {
            return WorkingTree(repository: name)
        }
        return WorkingTree(repository: repositoryName(sharing: directories.common), worktree: name)
    }

    /// What to call the repository a linked worktree belongs to, given the git directory they share.
    ///
    /// `<checkout>/.git` is the shape nearly every repository has, and there the checkout's own directory names it. A **bare** repository has no checkout to borrow a name from — `repo.git` sits beside its worktrees rather than inside anything — so the git directory names itself, minus the suffix that says what it is. Naming it after the directory that happens to *contain* it would answer `tree: src (worktree …)` for every worktree of every bare repository under one folder.
    ///
    /// **The one case this cannot name correctly is a linked worktree of a `--separate-git-dir` checkout, and no reachable question answers it** (verified against git 2.50.1). Such a repository holds no back-pointer to its checkout: the wiring runs the other way, from a `.git` *file* in the checkout to the git directory. `core.worktree` is unset, nothing else in the git directory names the checkout, and `git worktree list --porcelain` — asked from either tree — reports the main entry as the *git directory's* path, not the checkout's. So this answers `orchard-gitdir` where a reader would want `orchard`, which is git's own answer and the only one available; asking the checkout itself still gives `orchard`, because there the tree's own directory is what names it. Pinned in both directions by `WorkingTreeTests`, so a future git that records the back-pointer will fail the test rather than sit unnoticed.
    private static func repositoryName(sharing common: URL) -> String {
        let name = common.lastPathComponent
        guard name != ".git" else { return common.deletingLastPathComponent().lastPathComponent }
        return name.hasSuffix(".git") ? String(name.dropLast(".git".count)) : name
    }
}
