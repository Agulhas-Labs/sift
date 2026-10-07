//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

@Suite(.serialized)
struct TreeContentHashTests {
    /// Identical bytes hash identically, however the tree got back to them — the property the same-tree tier stands on.
    @Test func theSameBytesHashTheSameEvenAfterAnEditIsUndone() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
            try TestSources.commitAll(in: root, message: "widget")
            try TestSources.write("struct Widget { let size = 1 }", to: "Sources/Widget.swift", in: root)
            let first = try #require(TreeContentHash.of(repositoryRoot: root))
            try TestSources.write("struct Widget { let size = 2 }", to: "Sources/Widget.swift", in: root)
            try TestSources.write("struct Widget { let size = 1 }", to: "Sources/Widget.swift", in: root)
            #expect(TreeContentHash.of(repositoryRoot: root) == first)
        }
    }

    /// Two dirty trees on one `HEAD` — a change set aside and the change itself — hash apart, which neither `HEAD` nor dirtiness could do.
    @Test func twoDirtyTreesOnOneHeadHashApart() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
            try TestSources.commitAll(in: root, message: "widget")
            try TestSources.write("struct Widget { let size = 1 }", to: "Sources/Widget.swift", in: root)
            let fix = try #require(TreeContentHash.of(repositoryRoot: root))
            try TestSources.write("struct Widget { let size = 2 }", to: "Sources/Widget.swift", in: root)
            let other = try #require(TreeContentHash.of(repositoryRoot: root))
            #expect(fix != other)
        }
    }

    /// An untracked file is part of the tree, by its content and not only its name, and the tool's own directory is not.
    @Test func anUntrackedFileCountsByContentAndTheToolsOwnDirectoryDoesNot() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let clean = try #require(TreeContentHash.of(repositoryRoot: root))
            try TestSources.write("struct Gadget {}", to: "Sources/Gadget.swift", in: root)
            let added = try #require(TreeContentHash.of(repositoryRoot: root))
            try TestSources.write("struct Gadget { let size = 1 }", to: "Sources/Gadget.swift", in: root)
            let edited = try #require(TreeContentHash.of(repositoryRoot: root))
            #expect(Set([clean, added, edited]).count == 3)

            try TestSources.write("a transcript", to: "\(SiftPaths.directoryName)/runs/last.log", in: root)
            #expect(TreeContentHash.of(repositoryRoot: root) == edited)
        }
    }

    /// Hashing writes no object and touches no index, not even the refresh porcelain `git diff` makes of a file whose stat moved and bytes did not: a cost every test run pays leaves nothing behind it, and takes no lock a parallel commit could trip on.
    @Test func hashingADirtyTreeWritesNoObjectAndLeavesTheIndexAlone() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
            try TestSources.commitAll(in: root, message: "widget")
            let untouched = try #require(TreeContentHash.of(repositoryRoot: root))
            // Touched and byte-identical, its modification time moved well clear of the index's own.
            let readme = root.appendingPathComponent("README.md")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: readme.path)
            let objects = try TestSources.runGit(["count-objects", "-v"], in: root)
            let indexURL = root.appendingPathComponent(".git/index")
            let index = try Data(contentsOf: indexURL)
            let stat = try FileManager.default.attributesOfItem(atPath: indexURL.path)

            #expect(TreeContentHash.of(repositoryRoot: root) == untouched)
            try TestSources.write("struct Widget { let size = 1 }", to: "Sources/Widget.swift", in: root)
            try TestSources.write("struct Gadget {}", to: "Sources/Gadget.swift", in: root)
            #expect(TreeContentHash.of(repositoryRoot: root) != nil)

            let after = try FileManager.default.attributesOfItem(atPath: indexURL.path)
            #expect(try TestSources.runGit(["count-objects", "-v"], in: root) == objects)
            #expect(try Data(contentsOf: indexURL) == index)
            #expect(after[.systemFileNumber] as? Int == stat[.systemFileNumber] as? Int)
            #expect(after[.modificationDate] as? Date == stat[.modificationDate] as? Date)
        }
    }

    /// Past a bound the tree has no hash at all, never a hash of part of it that could equal a different tree's.
    @Test func untrackedBytesPastTheBoundHashToNothing() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let large = root.appendingPathComponent("capture.bin")
            #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
            let handle = try FileHandle(forWritingTo: large)
            // Sparse, so the size is past the bound without the bytes costing the disk anything.
            try handle.truncate(atOffset: UInt64(TreeContentHash.untrackedByteCap) + 1)
            try handle.close()

            #expect(TreeContentHash.of(repositoryRoot: root) == nil)
        }
    }

    /// An index entry git has been told not to stat hides an edit from the diff, so the tree refuses a hash.
    @Test func anIndexThatHidesAnEntryHashesToNothing() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.write("struct Widget {}", to: "Sources/Widget.swift", in: root)
            try TestSources.commitAll(in: root, message: "widget")
            try TestSources.runGit(["update-index", "--assume-unchanged", "Sources/Widget.swift"], in: root)

            #expect(TreeContentHash.of(repositoryRoot: root) == nil)
        }
    }

    /// A submodule with uncommitted content, or an untracked nested repository, holds bytes no diff of this repository carries, so the tree refuses a hash.
    @Test func aDirtySubmoduleOrAnUntrackedNestedRepositoryHashesToNothing() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            let vendor = try TestSources.makeTempRepo(at: root.appendingPathComponent("Vendor"))
            try TestSources.runGit(["add", "Vendor"], in: root)
            try TestSources.runGit(["commit", "-m", "vendor"], in: root)
            #expect(TreeContentHash.of(repositoryRoot: root) != nil)

            try TestSources.write("struct Gadget {}", to: "Gadget.swift", in: vendor)
            #expect(TreeContentHash.of(repositoryRoot: root) == nil)

            try FileManager.default.removeItem(at: vendor.appendingPathComponent("Gadget.swift"))
            #expect(TreeContentHash.of(repositoryRoot: root) != nil)
            _ = try TestSources.makeTempRepo(at: root.appendingPathComponent("Scratch"))
            #expect(TreeContentHash.of(repositoryRoot: root) == nil)
        }
    }

    /// An untracked file is hashed as its bytes on disk, so a configured clean filter is never run and writes nothing.
    @Test func aCleanFilterIsNeverRun() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()
            try TestSources.runGit(["config", "filter.stamp.clean", "touch stamped; cat"], in: root)
            try TestSources.write("*.dat filter=stamp\n", to: ".gitattributes", in: root)
            try TestSources.commitAll(in: root, message: "attributes")
            try TestSources.write("capture", to: "capture.dat", in: root)

            #expect(TreeContentHash.of(repositoryRoot: root) != nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stamped").path))
        }
    }

    /// Git gets a deadline, and a tree it does not describe in time has no hash.
    @Test func aTreeGitCannotDescribeInTimeHashesToNothing() throws {
        try TemporaryDirectory.withScope {
            let root = try TestSources.makeTempRepo()

            #expect(TreeContentHash.of(repositoryRoot: root, within: 0) == nil)
        }
    }

    /// One command line in one place is one invocation, whichever worktree it ran in; another directory is another.
    @Test func anInvocationIsTheCommandLineAndWhereInTheRepositoryItRan() {
        let first = URL(fileURLWithPath: "/repo/a")
        let second = URL(fileURLWithPath: "/repo/b")
        let arguments = ["swift", "test"]

        #expect(TreeContentHash.invocation(of: arguments, in: first, repositoryRoot: first) == TreeContentHash.invocation(of: arguments, in: second, repositoryRoot: second))
        #expect(TreeContentHash.invocation(of: arguments, in: first, repositoryRoot: first) != TreeContentHash.invocation(of: arguments, in: first.appendingPathComponent("Package"), repositoryRoot: first))
        #expect(TreeContentHash.invocation(of: arguments, in: first, repositoryRoot: first) != TreeContentHash.invocation(of: arguments + ["--filter", "steady"], in: first, repositoryRoot: first))
    }
}
