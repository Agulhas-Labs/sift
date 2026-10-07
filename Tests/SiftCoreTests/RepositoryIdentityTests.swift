//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the identity memo `siblingPointers` shares across `sameRepository` and `collapsingWorktrees` on one call — that it never remembers a failed answer, that it is never asked to outlive the call it was made for (through `siblingPointers` itself, not only through `RootResolver`), and that sharing it actually removes work.
@Suite(.temporaryDirectories)
struct RepositoryIdentityTests {
    private static func makeRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TestSources.makeTempDirectory().appendingPathComponent("roots.json"))
    }

    /// An indexed repo declaring `type`, recorded in `registry`.
    @discardableResult
    private static func makeIndexedRepo(declaring type: String, in registry: RootsRegistry) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct \(type) { public let value: Int }", to: "Sources/Lib/\(type).swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root, registry: registry)
        try await engine.ensureFresh()
        return root
    }

    /// A root's identity is never assumed to outlive the call that asked for it — because the path can answer for a different repository from one query to the next.
    ///
    /// A worktree torn down and rebuilt at the same path is exactly that: the string naming it never changes, but `git rev-parse --git-common-dir` run there now answers for whatever repository claimed the path. The old index sitting on disk at that path (never rebuilt — that is a staleness question, not this one) still declares what it always did, so the only thing standing between an honest ambiguity and a silently wrong single answer is asking git again rather than reusing what a previous call learned.
    @Test
    func aRootThatChangesWhichRepositoryItAnswersForIsNeverServedTheOldAnswer() async throws {
        let registry = try Self.makeRegistry()
        let first = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let worktree = try TestSources.makeWorktree(of: first, named: "audit")
        // Building an engine at the worktree indexes it (declaring the same `Depot` `first` does) and records it in the registry, exactly as an earlier query in the same session would have.
        let worktreeEngine = try SiftEngine(directory: worktree, registry: registry)
        try await worktreeEngine.ensureFresh()
        let portfolio = try TestSources.makeTempDirectory()

        // Before: the worktree shares `first`'s identity, so the pair collapses to one and the query resolves singly.
        let resolvedBefore = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
        #expect(resolvedBefore.url.standardizedFileURL == first.standardizedFileURL)

        // The path is handed to an unrelated repository — its git file now names a different git-common-dir, its old index left untouched on disk.
        let second = try TestSources.makeTempRepo()
        try "gitdir: \(second.appendingPathComponent(".git").path)".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        // After: the same query must not reuse the identity the first call learned. Two indexed roots genuinely disagree now, and that is reported, not guessed.
        do {
            _ = try RootResolver.resolve(directory: portfolio, registry: registry, probing: "Depot")
            Issue.record("a root that changed which repository it answers for was still collapsed into its old one")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("declared in 2 indexed repositories"))
            #expect(message.contains(first.path))
            #expect(message.contains(worktree.path))
        }
    }

    /// Sharing one memo across the pattern `siblingPointers` performs on every miss resolves each root once.
    ///
    /// That pattern is: ask whether each of several roots is the caller's own repository, then ask which repository each of the survivors collapses into. Independent calls resolve `own` again for every root asked about it, and resolve a root a second time if it survives into `collapsingWorktrees`.
    @Test
    func aSharedMemoResolvesEachRootOnceWhereIndependentCallsResolveSomeTwice() throws {
        let own = try TestSources.makeTempRepo()
        let alpha = try TestSources.makeTempRepo()
        let alphaWorktree = try TestSources.makeWorktree(of: alpha, named: "audit")
        let beta = try TestSources.makeTempRepo()
        let others = [alpha.path, alphaWorktree.path, beta.path]

        // Independent: each `sameRepository` call is its own caller, resolving both sides from nothing; the later `collapsingWorktrees` call is a third caller, unaware of what either already learned.
        var independent = 0
        for root in others {
            let memo = RepositoryIdentity.CallMemo()
            _ = RepositoryIdentity.sameRepository(root, own.path, memo: memo)
            independent += memo.rawResolutions
        }
        let independentCollapse = RepositoryIdentity.CallMemo()
        _ = RepositoryIdentity.collapsingWorktrees(of: [alpha.path, alphaWorktree.path], memo: independentCollapse)
        independent += independentCollapse.rawResolutions

        // Shared: one memo answers the same questions, in the same order a real miss asks them.
        let shared = RepositoryIdentity.CallMemo()
        for root in others {
            _ = RepositoryIdentity.sameRepository(root, own.path, memo: shared)
        }
        _ = RepositoryIdentity.collapsingWorktrees(of: [alpha.path, alphaWorktree.path], memo: shared)

        // own, alpha, alphaWorktree and beta — four roots, resolved once each.
        #expect(shared.rawResolutions == 4)
        #expect(shared.rawResolutions < independent)
    }

    /// A failed resolution is never remembered as if it were a real answer — because the memo is shared for the length of a call, and the ground truth it reports can change mid-call: a path can start answering for a repository it did not answer for a moment ago.
    ///
    /// Proven on one memo, asked the same question twice, with the ground truth changed in between: `notYetARepo` is not a repository at all when asked the first time, so identity falls back to its own canonical path — and that fallback must not be cached as though it were `notYetARepo`'s real identity. Once it genuinely is `repo`'s own worktree, the same memo must say so.
    @Test
    func aFailedResolutionIsNeverCachedByTheMemo() throws {
        let notYetARepo = try TestSources.makeTempDirectory()
        let repo = try TestSources.makeTempRepo()
        let memo = RepositoryIdentity.CallMemo()

        #expect(!RepositoryIdentity.sameRepository(notYetARepo.path, repo.path, memo: memo))

        // Now `notYetARepo` is a second working tree sharing `repo`'s git directory — a bare gitfile, not a linked worktree, so its own root equals its common one; its stored index, if it had one, would be untouched, and here there is none to speak of, only the identity question.
        try "gitdir: \(repo.appendingPathComponent(".git").path)".write(
            to: notYetARepo.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        // The same memo, asked again: the earlier failure must not still be standing in for an answer.
        #expect(RepositoryIdentity.sameRepository(notYetARepo.path, repo.path, memo: memo))
        // A fresh memo agrees, which is what proves the shared one was the thing under test.
        #expect(RepositoryIdentity.sameRepository(notYetARepo.path, repo.path, memo: RepositoryIdentity.CallMemo()))
    }

    /// The memo `siblingPointers` builds is scoped to the one miss it answers, not to the engine that owns it — so a root that changes which repository it answers for between two misses is asked about fresh on the second, not answered from what the first already decided.
    ///
    /// This goes through the real caller rather than `RepositoryIdentity` directly, unlike the test above: a memo hoisted onto `SiftEngine` as a stored property would keep collapsing the worktree into `declaring` forever, and only a test that revisits the *same* engine across two misses would notice that.
    @Test
    func siblingPointersNeverCarriesItsCollapseFromOneMissToTheNext() async throws {
        let registry = try Self.makeRegistry()
        let declaring = try await Self.makeIndexedRepo(declaring: "Depot", in: registry)
        let worktree = try TestSources.makeWorktree(of: declaring, named: "audit")
        let worktreeEngine = try SiftEngine(directory: worktree, registry: registry)
        try await worktreeEngine.ensureFresh()

        let own = try TestSources.makeTempRepo()
        let ownEngine = try SiftEngine(directory: own, registry: registry)
        try await ownEngine.ensureFresh()

        // Before: `declaring` and its worktree are one repository, so the miss collapses to a single pointer.
        let before = try ownEngine.digest(target: "Depot", options: DigestOptions())
        #expect(before.components(separatedBy: "is declared in").count - 1 == 1)
        #expect(before.contains(declaring.path))

        // The worktree's `.git` now names a different repository — its stored index, declaring `Depot`, is left untouched on disk.
        let second = try TestSources.makeTempRepo()
        try "gitdir: \(second.appendingPathComponent(".git").path)".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        // After, on the SAME engine: the pointers must change, not repeat the collapsed answer from before.
        let after = try ownEngine.digest(target: "Depot", options: DigestOptions())
        #expect(after != before)
        #expect(after.components(separatedBy: "is declared in").count - 1 == 2)
    }
}
