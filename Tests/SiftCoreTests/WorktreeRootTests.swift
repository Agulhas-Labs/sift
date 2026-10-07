//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A **regression guard, not a fix-pin**: these tests pass without any change to the sources, and are meant to.
///
/// The defect they describe — a caller in a linked worktree served the primary checkout's view of its own files — is closed above this layer, and not by anything here. What closes it is ``SiftMCP/CallerRoot``, which pins a rootless MCP call to the caller's own `cwd` from the `PreToolUse` payload, and the `tree:` field of the header that ``WorkingTree`` builds, which makes a mismatch visible when the pinning is absent. Nothing in this file would fail if either were reverted in isolation, because both sit above ``SiftEngine``, which resolves from the caller's directory correctly on its own.
///
/// What it adds is cover at the level the defect is *seen* at. The other tests of this area assert a path or a header string; none asserts the thing that goes wrong, which is the content. A worktree and the checkout it was cut from hold the same symbol names, so serving one for the other produces an answer that is complete, plausible, and about a different tree — on a branch that adds a declaration, the declaration is simply missing and nothing says so. So the fixture makes the two trees disagree about one file rather than merely sit at different paths, and asserts both directions. A future change that reintroduced the confusion anywhere below the front ends would fail here rather than in a header comparison.
@Suite(.temporaryDirectories)
struct WorktreeRootTests {
    private static var onTheCheckout: String {
        """
        public enum Palette {
            case base
        }
        """
    }

    private static var onTheBranch: String {
        """
        public enum Palette {
            case base
            case branchOnlyRamp
        }
        """
    }

    /// A checkout and a worktree of it whose `Sources/Palette.swift` differ by one case, each committed on its own branch.
    private static func makeDivergedTrees() throws -> (checkout: URL, worktree: URL) {
        let checkout = try TestSources.makeTempRepo()
        try TestSources.write(onTheCheckout, to: "Sources/Palette.swift", in: checkout)
        try TestSources.commitAll(in: checkout, message: "the ramp as the checkout has it")
        let worktree = try TestSources.makeWorktree(of: checkout, named: "agent-3f0a91b2")
        try TestSources.write(onTheBranch, to: "Sources/Palette.swift", in: worktree)
        try TestSources.commitAll(in: worktree, message: "a case only this branch has")
        return (checkout, worktree)
    }

    private static func digest(of target: String, in directory: URL) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        try await engine.ensureFresh()
        return try engine.digest(target: target, options: DigestOptions())
    }

    /// The whole defect, in the terms a caller meets it in: a declaration that exists only on the worktree's branch.
    @Test
    func aDeclarationMadeOnlyOnTheWorktreesBranchIsWhatTheWorktreeIsServed() async throws {
        let trees = try Self.makeDivergedTrees()

        let served = try await Self.digest(of: "Palette", in: trees.worktree)
        let fromTheCheckout = try await Self.digest(of: "Palette", in: trees.checkout)

        #expect(served.contains("branchOnlyRamp"))
        // And the converse, which is what makes the assertion above mean something: the case really is
        // absent from the other tree, so an answer carrying it could only have come from this one.
        #expect(!fromTheCheckout.contains("branchOnlyRamp"))
    }

    /// A query made from *inside* the worktree resolves to the worktree, not to the repository it was cut from.
    ///
    /// The caller's directory is almost never the root — it is wherever the session is standing — so resolving from a subdirectory is the case that actually runs.
    @Test
    func aQueryFromASubdirectoryOfAWorktreeResolvesToTheWorktree() throws {
        let trees = try Self.makeDivergedTrees()

        let engine = try SiftEngine(directory: trees.worktree.appendingPathComponent("Sources"))

        #expect(CanonicalPath.of(engine.repoRoot.path) == CanonicalPath.of(trees.worktree.path))
        #expect(CanonicalPath.of(engine.repoRoot.path) != CanonicalPath.of(trees.checkout.path))
    }

    /// Contract §1 on the axis the `tree:` field cannot carry: `head:` is the *worktree's* commit, not the one the repository it was cut from is sitting on.
    ///
    /// `WorkingTreeTests.theHeaderOfAWorktreeIsNotTheHeaderOfTheCheckoutItCameFrom` already covers the `tree:` half, and covers it in the harder arrangement — two trees at the *same* commit, where `tree:` is the only field that can tell them apart. So this asserts only what that one cannot: two branches that have moved apart, where a reader served the wrong tree can see it in the revision alone.
    @Test
    func theHeaderNamesTheCommitTheAnswerWasMeasuredAgainst() async throws {
        let trees = try Self.makeDivergedTrees()
        let checkoutHead = try Self.headShort(of: trees.checkout)
        let worktreeHead = try Self.headShort(of: trees.worktree)
        #expect(checkoutHead != worktreeHead)

        let header = try await SiftEngine(directory: trees.worktree).ensureFresh().headerLine

        #expect(header.contains("head: \(worktreeHead)"))
        #expect(!header.contains("head: \(checkoutHead)"))
    }

    private static func headShort(of root: URL) throws -> String {
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root)
        return String(head.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
    }
}
