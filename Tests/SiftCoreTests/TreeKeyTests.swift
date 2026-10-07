//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

@Suite(.serialized)
struct TreeKeyTests {
    @Test func theSameTreeKeysTheSameTwice() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let first = try #require(TreeKey.of(repositoryRoot: root))
            let second = try #require(TreeKey.of(repositoryRoot: root))
            #expect(first == second)
        }
    }

    @Test func aCommitThatOnlyRewordsItsMessageLeavesTheKeyAlone() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let before = try #require(TreeKey.of(repositoryRoot: root))
            let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root)
            try TestSources.runGit(["commit", "-q", "--amend", "-m", "a different message"], in: root)
            let after = try #require(TreeKey.of(repositoryRoot: root))
            let reworded = try TestSources.runGit(["rev-parse", "HEAD"], in: root)
            #expect(reworded != head)
            #expect(after == before)
        }
    }

    @Test func aTrackedFileEditedInTheWorkingTreeMovesTheKey() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
            try TestSources.commitAll(in: root, message: "widget")
            let before = try #require(TreeKey.of(repositoryRoot: root))
            try TestSources.write("struct Widget { let size = 1 }", to: "Sources/Widget.swift", in: root)
            let edited = try #require(TreeKey.of(repositoryRoot: root))
            #expect(edited != before)
        }
    }

    /// An index that hides an entry from the walk answers no key at all, in either of git's two spellings.
    ///
    /// Both bits stop git stat-ing the file, so the walk reads the index's copy and an edited tree keys identically to the clean one it was proved on. That is the one uncovered hazard a record's age cannot bound: it is set once and then applies to every run after it. Refusing the key refuses both halves at once — nothing records against such a tree, and nothing recorded is trusted for it.
    @Test func anIndexThatHidesAnEntryFromTheWalkAnswersNoKey() throws {
        try TemporaryDirectory.withScope {
            for hiding in ["--assume-unchanged", "--skip-worktree"] {
                let root = try TestSources.makeTempRepo()
                try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
                try TestSources.commitAll(in: root, message: "widget")
                #expect(TreeKey.of(repositoryRoot: root) != nil)

                try TestSources.runGit(["update-index", hiding, "Sources/Widget.swift"], in: root)

                #expect(TreeKey.of(repositoryRoot: root) == nil, "\(hiding) left a key that an edit cannot move")
            }
        }
    }

    @Test func anUntrackedFileMovesTheKeyAndAnIgnoredOneDoesNot() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("build/\n", to: ".gitignore", in: root)
            try TestSources.commitAll(in: root, message: "ignore the build")
            let before = try #require(TreeKey.of(repositoryRoot: root))
            try TestSources.write("ignore me", to: "build/artifact.txt", in: root)
            let ignored = try #require(TreeKey.of(repositoryRoot: root))
            #expect(ignored == before)
            try TestSources.write("struct New {}", to: "Sources/New.swift", in: root)
            let added = try #require(TreeKey.of(repositoryRoot: root))
            #expect(added != before)
        }
    }

    /// The key is taken over a scratch index, so nothing it does may show up as the caller's work being staged.
    @Test func keyingTheTreeStagesNothingOfTheCallersOwn() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Loose {}", to: "Sources/Loose.swift", in: root)
            _ = TreeKey.of(repositoryRoot: root)
            let status = try TestSources.runGit(["status", "--porcelain"], in: root)
            #expect(status.contains("Sources/"))
            #expect(!status.split(separator: "\n").contains { $0.hasPrefix("A") })
        }
    }

    /// Every scratch file is the tool's own, and none of it may outlive the call that made it.
    @Test func theScratchIndexIsRemovedWhenTheKeyIsTaken() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            _ = TreeKey.of(repositoryRoot: root)
            let cache = SiftPaths.cache(in: root)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            #expect(!left.contains { $0.hasPrefix("tree-index-") })
        }
    }

    @Test func aDirectoryThatIsNoRepositoryHasNoKey() throws {
        try TemporaryDirectory.withScope {
            let plain = try TestSources.makeTempDirectory()
            #expect(TreeKey.of(repositoryRoot: plain) == nil)
        }
    }
}
