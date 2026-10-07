//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `DiffRange.resolve`: what a bare, ranged, three-dot or single-commit `sift diff` argument means — and the spellings it refuses, in its own words and with one that works.
@Suite(.temporaryDirectories)
struct DiffRangeTests {
    /// A repository whose `main` and `feature` have each moved on since they parted — the shape that tells `A..B` from `A...B`.
    private static func divergedRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.runGit(["branch", "feature"], in: root)
        try TestSources.write("main\n", to: "MAIN.md", in: root)
        try TestSources.commitAll(in: root, message: "main moves on")
        try TestSources.runGit(["switch", "-q", "feature"], in: root)
        try TestSources.write("feature\n", to: "FEATURE.md", in: root)
        try TestSources.commitAll(in: root, message: "feature moves on")
        try TestSources.runGit(["switch", "-q", "main"], in: root)
        return root
    }

    private static func hash(_ rev: String, in root: URL) throws -> String {
        try TestSources.runGit(["rev-parse", rev], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func refusal(_ argument: String, in root: URL) -> DiffRange.Refusal? {
        do {
            _ = try DiffRange.resolve(argument, git: GitContext(repoRoot: root))
            return nil
        } catch {
            return error as? DiffRange.Refusal
        }
    }

    @Test func noArgumentReadsAsTheWorkingTreeAgainstHead() throws {
        let root = try TestSources.makeTempRepo()
        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))

        #expect(range.from == "HEAD")
        #expect(range.to == .workingTree)
        #expect(range.described.hasPrefix("working tree vs HEAD"))
    }

    @Test func aTwoDotRangeNamesBothEndpointsInOrder() throws {
        let root = try Self.divergedRepo()
        let range = try DiffRange.resolve("main..feature", git: GitContext(repoRoot: root))

        #expect(range.from == "main")
        #expect(range.to == .revision("feature"))
        #expect(range.described == "main..feature")
    }

    /// `A...B` is B against where the two parted — so what only `main` did since then is not part of the branch's review.
    @Test func threeDotsCompareTheRightSideAgainstTheMergeBase() throws {
        let root = try Self.divergedRepo()
        let base = try TestSources.runGit(["merge-base", "main", "feature"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let range = try DiffRange.resolve("main...feature", git: GitContext(repoRoot: root))

        #expect(range.from == base)
        #expect(range.to == .revision("feature"))
        #expect(range.described.hasPrefix("main...feature — feature against its merge-base with main"))
    }

    /// git would fill an empty side with `HEAD`; this refuses rather than guess, and names the spelling that works.
    @Test func aRangeWithAnEmptySideIsRefusedNamingBothEnds() throws {
        let root = try Self.divergedRepo()

        let noRight = try #require(Self.refusal("HEAD~1..", in: root))
        let noLeft = try #require(Self.refusal("..feature", in: root))
        let noThreeDotRight = try #require(Self.refusal("feature...", in: root))

        #expect(noRight.message.contains("`sift diff HEAD~1..HEAD`"))
        #expect(noLeft.message.contains("`sift diff HEAD..feature`"))
        #expect(noThreeDotRight.message.contains("`sift diff feature...HEAD`"))
        #expect(!noRight.message.contains(GitContext.emptyTreeHash))
    }

    /// Filling the empty side with `HEAD` when the other side is `HEAD` compares a commit with itself; the refusal never suggests a spelling that answers "nothing changed".
    @Test func anEmptySideNextToHeadIsNeverRefilledWithHead() throws {
        let root = try Self.divergedRepo()

        let noLeft = try #require(Self.refusal("..HEAD", in: root))
        let noRight = try #require(Self.refusal("HEAD...", in: root))
        let sameCommit = try #require(Self.refusal("main..", in: root))

        #expect(!noLeft.message.contains("HEAD..HEAD"))
        #expect(noLeft.message.contains("`sift diff HEAD` for that commit's own change"))
        #expect(!noRight.message.contains("HEAD...HEAD"))
        #expect(noRight.message.contains("`sift diff` with no range for the working tree against HEAD"))
        #expect(!sameCommit.message.contains("main..HEAD`"))
    }

    /// Never git's usage text, and never the empty-tree object the caller did not type.
    @Test func aNameThatIsNoCommitIsRefusedInThisToolsOwnWords() throws {
        let root = try Self.divergedRepo()

        let single = try #require(Self.refusal("nonexistent", in: root))
        let ranged = try #require(Self.refusal("main..nonexistent", in: root))

        #expect(single.message.contains("`nonexistent` does not name a commit in this repository"))
        #expect(ranged.message.contains("`nonexistent` in `main..nonexistent` does not name a commit"))
        #expect(!single.message.contains(GitContext.emptyTreeHash))
        #expect(!single.message.contains("usage:"))
    }

    @Test func caretBangIsTheCommitsOwnChange() throws {
        let root = try Self.divergedRepo()
        let range = try DiffRange.resolve("HEAD^!", git: GitContext(repoRoot: root))

        #expect(range.from == "HEAD^")
        #expect(range.to == .revision("HEAD"))
        #expect(range.described.hasPrefix("HEAD^! — that commit against its parent"))
    }

    @Test func aSingleCommitWithAParentReadsAsItsOwnChange() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("second\n", to: "SECOND.md", in: root)
        try TestSources.commitAll(in: root, message: "second")
        let head = try Self.hash("HEAD", in: root)
        let range = try DiffRange.resolve(head, git: GitContext(repoRoot: root))

        #expect(range.from == "\(head)^")
        #expect(range.to == .revision(head))
        #expect(range.described == "\(head) — that commit against its parent")
    }

    /// A merge is read against its first parent — the change it brought to the branch it landed on — and says so, since that is not the combined diff `git show` prints for one.
    @Test func aMergeCommitIsReadAgainstItsFirstParentAndSaysSo() throws {
        let root = try Self.divergedRepo()
        try TestSources.runGit(["merge", "--no-ff", "-q", "-m", "merge", "feature"], in: root)
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))

        #expect(range.from == "HEAD^")
        #expect(range.described.contains("a merge commit, against its first parent"))
    }

    /// A root commit has no parent to name — `<rev>^` does not resolve — so the range reads against git's empty-tree object instead of failing outright.
    @Test func aRootCommitDiffsAgainstTheEmptyTree() throws {
        let root = try TestSources.makeTempRepo()
        let head = try Self.hash("HEAD", in: root)
        let range = try DiffRange.resolve(head, git: GitContext(repoRoot: root))

        #expect(range.from == GitContext.emptyTreeHash)
        #expect(range.to == .revision(head))
        #expect(range.fromLabel == "the empty tree")
    }

    @Test func affectedRangeMirrorsDiffsOwnDefaultAtTheDefault() throws {
        let root = try Self.divergedRepo()
        #expect(try DiffRange.resolve(nil, git: GitContext(repoRoot: root)).affectedRange == nil)

        let named = try DiffRange.resolve("main..feature", git: GitContext(repoRoot: root))
        #expect(named.affectedRange == AffectedOptions.CommitRange(from: "main", to: "feature"))
        #expect(named.affectedCommand == "sift affected --from main --to feature")
    }

    /// A fresh repository with nothing committed yet has no `HEAD` to diff against — the default range reads it as the empty tree instead, the way a root commit already does for its absent parent.
    @Test func noArgumentOnAnUnbornHeadReadsAsTheEmptyTree() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-q", "-b", "main"], in: root)
        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))

        #expect(range.from == GitContext.emptyTreeHash)
        #expect(range.fromLabel == "the empty tree")
        #expect(range.to == .workingTree)
        #expect(range.described.hasPrefix("working tree vs an empty repository"))
    }
}
