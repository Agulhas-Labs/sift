//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Contract §1: the header names the state the answer was measured against — and *which tree* is part of that state.
@Suite(.temporaryDirectories)
struct WorkingTreeTests {
    /// The header two trees of one repository produce has to differ.
    ///
    /// A worktree and its checkout share `head:` and hold the same symbols, so without a tree field `dirty:` is the only one that can ever move — and a reader with no baseline cannot tell a worktree's `dirty: 0` from a parent's. Two answers from two trees would be byte-identical in the header.
    @Test
    func theHeaderOfAWorktreeIsNotTheHeaderOfTheCheckoutItCameFrom() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let worktree = try TestSources.makeWorktree(of: root, named: "agent-1a2b3c4d")

        let checkoutHeader = try await SiftEngine(directory: root).ensureFresh().headerLine
        let worktreeHeader = try await SiftEngine(directory: worktree).ensureFresh().headerLine

        #expect(checkoutHeader.hasPrefix("tree: \(root.lastPathComponent)  head: "))
        #expect(worktreeHeader.hasPrefix("tree: \(root.lastPathComponent) (worktree agent-1a2b3c4d)  head: "))
        #expect(checkoutHeader != worktreeHeader)
    }

    /// A finished answer's header gives back the tree it was written from, and so the directory that tree is checked out in — the one thing a reader of the answer has to place its relative paths by.
    @Test
    func theTreeIsReadBackOutOfAFinishedAnswersHeader() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let worktree = try TestSources.makeWorktree(of: root, named: "agent-1a2b3c4d")

        let checkoutHeader = try await SiftEngine(directory: root).ensureFresh().headerLine
        let worktreeHeader = try await SiftEngine(directory: worktree).ensureFresh().headerLine
        let live = Freshness.liveHeaderLine(tree: WorkingTree.describing(worktree))

        #expect(WorkingTree.named(inAnswer: checkoutHeader + "\nbody") == WorkingTree.describing(root))
        #expect(WorkingTree.named(inAnswer: checkoutHeader)?.directoryName == root.lastPathComponent)
        #expect(WorkingTree.named(inAnswer: "notice above the header\n" + worktreeHeader) == WorkingTree.describing(worktree))
        #expect(WorkingTree.named(inAnswer: worktreeHeader)?.directoryName == "agent-1a2b3c4d")
        #expect(WorkingTree.named(inAnswer: live)?.directoryName == "agent-1a2b3c4d")
        #expect(WorkingTree.named(inAnswer: "Sources/Alpha.swift — module: Alpha") == nil)
    }

    /// The repository's own checkout is not marked, because there is nothing to distinguish it from.
    @Test
    func aRepositorysOwnCheckoutCarriesNoWorktreeMarker() throws {
        let root = try TestSources.makeTempRepo()

        let tree = WorkingTree.describing(root)

        #expect(tree.repository == root.lastPathComponent)
        #expect(tree.worktree == nil)
        #expect(tree.rendered == root.lastPathComponent)
    }

    /// A linked worktree is named by *both*: the repository it belongs to, which its own path never says, and its own directory, which is what tells two worktrees of that repository apart.
    @Test
    func aWorktreeNamesTheRepositoryItBelongsToAsWellAsItself() throws {
        let root = try TestSources.makeTempRepo()
        let worktree = try TestSources.makeWorktree(of: root, named: "sweep")

        let tree = WorkingTree.describing(worktree)

        #expect(tree.repository == root.lastPathComponent)
        #expect(tree.worktree == worktree.lastPathComponent)
        #expect(tree.rendered == "\(root.lastPathComponent) (worktree \(worktree.lastPathComponent))")
    }

    /// The Wording rule keeps absolute paths out of answers meant to be shared, and the header is the line that gets pasted.
    @Test
    func theTreeFieldNamesNoPath() throws {
        let root = try TestSources.makeTempRepo()
        let worktree = try TestSources.makeWorktree(of: root, named: "shared")

        for tree in [WorkingTree.describing(root), WorkingTree.describing(worktree)] {
            #expect(!tree.rendered.contains("/"))
        }
    }

    /// A directory git cannot answer for keeps its own name, which is the honest answer when there is nothing else to say — and never an empty field.
    @Test
    func aDirectoryOutsideAnyRepositoryKeepsItsOwnName() throws {
        let outside = try TestSources.makeTempDirectory()

        let tree = WorkingTree.describing(outside)

        #expect(tree.rendered == outside.lastPathComponent)
        #expect(!tree.rendered.isEmpty)
    }

    /// A bare repository has no checkout to lend the header its name, and the folder that happens to hold it is not the repository.
    ///
    /// `repo.git` sits beside its worktrees rather than inside a checkout, so naming the repository after the git directory's *parent* names the container — every worktree of every bare repository under one folder reporting that folder as its repository, which is exactly as wrong for two repositories as it is for one.
    @Test
    func aWorktreeOfABareRepositoryIsNamedAfterTheRepositoryAndNotTheFolderHoldingIt() throws {
        let bare = try TestSources.makeBareRepo(named: "orchard")
        let worktree = try TestSources.makeWorktree(ofBare: bare, named: "review")

        let tree = WorkingTree.describing(worktree)

        #expect(tree.repository == "orchard")
        #expect(tree.worktree == "review")
        #expect(tree.rendered == "orchard (worktree review)")
        #expect(tree.repository != bare.deletingLastPathComponent().lastPathComponent)
    }

    /// A checkout whose git directory lives somewhere else entirely is still that repository's main working tree, and carries no worktree marker.
    ///
    /// The marker is a claim that there is another tree this one could be confused with. Here there is not — and the arithmetic that produced it (git directory's parent, compared to the root) had no way to know, because with `--separate-git-dir` neither path says anything about the other.
    @Test
    func aCheckoutWhoseGitDirectoryLivesElsewhereCarriesNoWorktreeMarker() throws {
        let repo = try TestSources.makeRepoWithSeparateGitDirectory(named: "orchard")

        let tree = WorkingTree.describing(repo.checkout)

        #expect(tree.repository == "orchard")
        #expect(tree.worktree == nil)
        #expect(tree.rendered == "orchard")
    }

    /// Its *worktree* is named after the git directory, because git records nothing that would name the checkout — the one case the header cannot get right.
    ///
    /// Asserted rather than left unpinned, and asserted in both directions, because the wrong-looking half is the honest one: `git worktree list --porcelain` asked from this worktree reports the main entry as the git directory's path, `core.worktree` is unset, and nothing else under the git directory names the checkout — the wiring runs from a `.git` *file* in the checkout outwards, and only outwards. So `orchard-gitdir` is git's own answer and the only one obtainable; the assertion below that the checkout still says `orchard` is what keeps this a naming limit rather than a resolution bug. A future git that records the back-pointer fails this test, which is the point of writing it down.
    @Test
    func aWorktreeOfACheckoutWhoseGitDirectoryLivesElsewhereIsNamedAfterTheGitDirectory() throws {
        let repo = try TestSources.makeRepoWithSeparateGitDirectory(named: "orchard")
        let worktree = repo.checkout.deletingLastPathComponent().appendingPathComponent("review")
        try TestSources.runGit(["worktree", "add", "-b", "review", worktree.path], in: repo.checkout)

        let tree = WorkingTree.describing(worktree)

        // Stated as the literal git answers with, not as the expression that computes it.
        #expect(tree.repository == "orchard-gitdir")
        #expect(tree.repository == repo.gitDirectory.lastPathComponent)
        #expect(tree.worktree == "review")
        // The resolution is right even where the name is not: this really is a linked worktree, and the
        // repository's own checkout — asked directly, where its own directory names it — still says `orchard`.
        #expect(WorkingTree.describing(repo.checkout).repository == "orchard")
    }
}
