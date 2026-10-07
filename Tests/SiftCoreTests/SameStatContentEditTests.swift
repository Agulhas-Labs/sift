//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an edit that keeps the file's size and mtime: whether it changed is settled by content, on the query path for the files git names and in reconcile for every file, and where a digest serves source from a file git does not name, by the bytes it reads (``UnreportedEditDigestTests``).
@Suite(.temporaryDirectories)
struct SameStatContentEditTests {
    private static var path: String {
        "Sources/App/Alpha.swift"
    }

    private static var before: String {
        "struct Alpha {}\n"
    }

    private static var after: String {
        "struct Gamma {}\n"
    }

    @Test
    func aSameStatEditToADirtyFileIsReparsedBeforeAnswering() async throws {
        let (root, engine) = try await Self.indexedRepo()
        try Self.rewriteKeepingStat(Self.after, in: root)

        let freshness = try await engine.ensureFresh()
        let gamma = try engine.digest(target: "Gamma", options: DigestOptions())
        let alpha = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 1)
        #expect(gamma.contains("struct Gamma"))
        #expect(!alpha.contains("struct Alpha"))
    }

    @Test
    func aCommittedSameStatEditIsReparsedOnTheHeadMove() async throws {
        let (root, engine) = try await Self.indexedRepo()
        try Self.rewriteKeepingStat(Self.after, in: root)
        try TestSources.commitAll(in: root, message: "rename alpha")

        let freshness = try await engine.ensureFresh()
        let gamma = try engine.digest(target: "Gamma", options: DigestOptions())

        #expect(freshness.dirtyCount == 0)
        #expect(gamma.contains("struct Gamma"))
    }

    /// Git is told not to look at the file, so no query names it: only reconcile, which hashes every equal-sized file, can see the edit.
    @Test
    func reconcileReparsesASameStatEditNoQueryNames() async throws {
        let (root, engine) = try await Self.indexedRepo()
        try TestSources.runGit(["update-index", "--assume-unchanged", Self.path], in: root)
        try Self.rewriteKeepingStat(Self.after, in: root)

        let result = try await engine.reconcile()
        let gamma = try engine.digest(target: "Gamma", options: DigestOptions())

        #expect(result.reindexed == 1)
        #expect(gamma.contains("struct Gamma"))
    }

    /// The per-query bound: a query hashes the candidates git names, never the tree.
    ///
    /// Had it hashed the file git does not name, the hash would have differed and the file been reparsed, which the counter would show.
    @Test
    func aQueryHashesNoFileGitDoesNotName() async throws {
        let (root, engine) = try await Self.indexedRepo()
        try TestSources.runGit(["update-index", "--assume-unchanged", Self.path], in: root)
        try Self.rewriteKeepingStat(Self.after, in: root)

        _ = try await engine.ensureFresh()
        let gamma = try engine.digest(target: "Gamma", options: DigestOptions())

        #expect(try engine.store.metaValue("incremental_count") == nil)
        #expect(gamma.contains("no symbol named Gamma"))
    }

    /// A standing dirty file is hashed on each query and found unchanged, so it is parsed once, not once per query.
    @Test
    func aStandingSameStatEditIsParsedOnce() async throws {
        let (root, engine) = try await Self.indexedRepo()
        try Self.rewriteKeepingStat(Self.after, in: root)
        _ = try await engine.ensureFresh()
        let countAfterTheParse = try engine.store.metaValue("incremental_count")

        _ = try await engine.ensureFresh()
        _ = try await engine.ensureFresh()

        #expect(countAfterTheParse == "1")
        #expect(try engine.store.metaValue("incremental_count") == countAfterTheParse)
    }

    /// The other side of hashing: a file whose mtime moved and whose bytes did not is not reparsed by reconcile.
    @Test
    func reconcileDoesNotReparseAFileOnlyTouched() async throws {
        let (root, engine) = try await Self.indexedRepo()
        let url = root.appendingPathComponent(Self.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)

        let result = try await engine.reconcile()

        #expect(result.reindexed == 0)
        #expect(result.removed == 0)
    }

    private static func indexedRepo() async throws -> (URL, SiftEngine) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(before, to: path, in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return (root, engine)
    }

    /// Writes `text` over the fixture file and puts its mtime back, as `touch -r` or `cp -p` would, and requires that size and mtime really are what they were.
    private static func rewriteKeepingStat(_ text: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = root.appendingPathComponent(path)
        let original = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try #require(original[.modificationDate] as? Date, sourceLocation: sourceLocation)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let rewritten = try FileManager.default.attributesOfItem(atPath: url.path)
        try #require(rewritten[.size] as? Int64 == original[.size] as? Int64, sourceLocation: sourceLocation)
        let restored = try #require(rewritten[.modificationDate] as? Date, sourceLocation: sourceLocation)
        try #require(abs(restored.timeIntervalSince1970 - modified.timeIntervalSince1970) < 0.0001, sourceLocation: sourceLocation)
    }
}
