//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a digest that serves source from a file git is told not to report: the bytes it read are checked against the row, and a stale row is reparsed before the answer is rendered, so the outline and the source describe the same file and the header names it.
@Suite(.temporaryDirectories)
struct UnreportedEditDigestTests {
    private static var path: String {
        "Sources/App/Alpha.swift"
    }

    /// The fixture from the defect: the row holds `Alpha`, the file now holds `Gamma`, of the same size, and git does not list it.
    @Test
    func aServedTypeDigestOfAnAssumeUnchangedEditIsAnsweredFromTheLiveFile() async throws {
        let (root, engine) = try await Self.indexedRepo("struct Alpha {}\n")
        try TestSources.runGit(["update-index", "--assume-unchanged", Self.path], in: root)
        try TestSources.write("struct Gamma {}\n", to: Self.path, in: root)

        var freshness = try await engine.ensureFresh()
        let answer = try engine.measuredDigest(targets: ["Alpha"], options: DigestOptions())
        freshness.reparsedPaths = answer.reparsedPaths

        #expect(freshness.dirtyCount == 0)
        #expect(!answer.text.contains("struct Gamma {}"))
        #expect(answer.text.contains("no symbol named Alpha"))
        #expect(answer.reparsedPaths == [Self.path])
        #expect(freshness.headerLine.contains("dirty: 0 (+1 not in git status, reparsed from the live file: \(Self.path))  parse_errors:"))
        #expect(try engine.digest(target: "Gamma", options: DigestOptions()).contains("struct Gamma {}"))
    }

    /// The header's count is taken after the reparse, so it agrees with the banner the body carries for the same file.
    @Test
    func aReparsedFileThatNowHasParseErrorsIsCountedInTheHeader() async throws {
        let (root, engine) = try await Self.indexedRepo("struct Alpha {}\n")
        try TestSources.runGit(["update-index", "--assume-unchanged", Self.path], in: root)
        try TestSources.write("struct Alpha {{\n", to: Self.path, in: root)

        let freshness = try await engine.ensureFresh()
        let answer = try engine.measuredDigest(targets: [Self.path + ":1-1"], options: DigestOptions())
        let header = freshness.noting(answer).headerLine

        #expect(answer.reparsedPaths == [Self.path])
        #expect(freshness.parseErrorFiles == 0)
        #expect(header.contains("parse_errors: 1"))
    }

    /// A member body is sliced at the row's line range, so a stale row over a longer file would serve the wrong lines.
    @Test
    func aMemberBodyOfASkipWorktreeEditIsSlicedAtTheLiveRange() async throws {
        let (root, engine) = try await Self.indexedRepo("struct Alpha {\n    func run() {}\n}\n")
        try TestSources.runGit(["update-index", "--skip-worktree", Self.path], in: root)
        try TestSources.write("struct Alpha {\n    let count = 1\n\n    func run() {\n        _ = count\n    }\n}\n", to: Self.path, in: root)

        _ = try await engine.ensureFresh()
        let answer = try engine.measuredDigest(targets: ["Alpha.run"], options: DigestOptions())

        #expect(answer.text.contains("\(Self.path):4-6"))
        #expect(answer.text.contains("    func run() {\n        _ = count\n    }"))
        #expect(!answer.text.contains("let count"))
        #expect(answer.reparsedPaths == [Self.path])
    }

    /// A row that matches its file is read and hashed but never reparsed, and the header carries nothing extra.
    @Test
    func aServedDigestOfAnUnchangedFileReparsesNothing() async throws {
        let (_, engine) = try await Self.indexedRepo("struct Alpha {}\n")

        var freshness = try await engine.ensureFresh()
        let answer = try engine.measuredDigest(targets: ["Alpha"], options: DigestOptions())
        freshness.reparsedPaths = answer.reparsedPaths

        #expect(answer.text.contains("struct Alpha {}"))
        #expect(answer.reparsedPaths.isEmpty)
        #expect(freshness.headerLine.contains("  clean  semantic:"))
        #expect(!freshness.headerLine.contains("dirty:"))
    }

    private static func indexedRepo(_ text: String) async throws -> (URL, SiftEngine) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(text, to: path, in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return (root, engine)
    }
}
