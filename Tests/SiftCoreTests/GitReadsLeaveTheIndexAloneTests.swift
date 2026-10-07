//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every git read this tool makes against a working tree leaves `.git/index` exactly as it found it: the same file, the same modification time, the same bytes.
///
/// Other sessions work in the same checkout, and git's porcelain reads write the index behind the caller's back: `git status` and `git diff` both refresh its stat cache and write the refresh back, taking `index.lock` to do it. For that instant another session's `git add` or `git commit` fails with `Unable to create '.git/index.lock': File exists`. The fixture is the state that makes them do it — a committed file whose modification time has moved and whose content has not, the way a build, a checkout or an editor saving unchanged leaves one — and each read must also still say that file has not changed.
@Suite(.temporaryDirectories)
struct GitReadsLeaveTheIndexAloneTests {
    @Test
    func theChangedFilesReadAfterARunLeavesTheIndexAlone() throws {
        let root = try Self.repositoryWithATouchedFile()

        let changed = try Self.expectIndexUntouched(in: root) {
            RunChangedFiles.inWorkingTree(at: root)
        }

        #expect(changed == .basenames([]))
    }

    @Test
    func theQueryTimeDirtySetLeavesTheIndexAlone() throws {
        let root = try Self.repositoryWithATouchedFile()

        let dirty = try Self.expectIndexUntouched(in: root) {
            try GitContext(repoRoot: root).dirtyFiles()
        }

        #expect(dirty.isEmpty)
    }

    @Test
    func lineStatsAgainstTheWorkingTreeLeaveTheIndexAlone() throws {
        let root = try Self.repositoryWithATouchedFile()

        let stats = try Self.expectIndexUntouched(in: root) {
            try GitContext(repoRoot: root).lineStats(from: "HEAD")
        }

        #expect(stats.isEmpty)
    }

    @Test
    func theDiffSizeAgainstTheWorkingTreeLeavesTheIndexAlone() throws {
        let root = try Self.repositoryWithATouchedFile()

        let bytes = try Self.expectIndexUntouched(in: root) {
            try GitContext(repoRoot: root).diffByteCount(from: "HEAD")
        }

        #expect(bytes == 0)
    }
}

private extension GitReadsLeaveTheIndexAloneTests {
    /// What rewriting the index would change: a rewrite lands through a rename, so a new inode, a new modification time, and a refreshed stat cache in the bytes.
    struct IndexFingerprint: Equatable {
        let inode: UInt64?
        let modified: Date?
        let bytes: Data
    }

    /// A repository with one committed file whose modification time is an hour earlier than git recorded and whose content is what git recorded.
    ///
    /// The time is set outright rather than by waiting, so git's view of the file differs by its stat every time the test runs; an hour in the past rather than in the future, so the entry is never one git treats as racily clean.
    static func repositoryWithATouchedFile(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum A {}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.commitAll(in: root, message: "add")
        let path = root.appendingPathComponent("Sources/App/Catalogue.swift").path
        let recorded = try #require(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, sourceLocation: sourceLocation)
        try FileManager.default.setAttributes([.modificationDate: recorded.addingTimeInterval(-3600)], ofItemAtPath: path)
        return root
    }

    /// Runs `read` and expects `.git/index` to be the same file, with the same modification time and bytes, afterwards as before.
    ///
    /// A caller that exported `GIT_OPTIONAL_LOCKS=0` before running this suite cannot mask a regression here: every read under test starts from ``ProcessEnvironment/withoutGit(from:)``, which drops every `GIT_` key, and sets the variable itself (``GitContext/readEnvironment()`` and its siblings).
    static func expectIndexUntouched<Answer>(
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ read: () throws -> Answer
    ) throws -> Answer {
        let before = try fingerprint(in: root)
        let answer = try read()
        #expect(try fingerprint(in: root) == before, "the read rewrote .git/index", sourceLocation: sourceLocation)
        return answer
    }

    static func fingerprint(in root: URL) throws -> IndexFingerprint {
        let index = root.appendingPathComponent(".git/index")
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        return try IndexFingerprint(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            modified: attributes[.modificationDate] as? Date,
            bytes: Data(contentsOf: index)
        )
    }
}
