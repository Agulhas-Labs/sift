//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A stale file the digest could not reparse keeps its old rows, so the header must not claim it was reparsed from the live file.
@Suite(.temporaryDirectories)
struct UnparseableStaleDigestTests {
    private static var path: String {
        "Sources/App/Alpha.swift"
    }

    /// The fixture from the defect: git is told to overlook the file, then its bytes stop being UTF-8.
    @Test
    func aStaleFileThatCannotBeParsedIsNamedAsNotReparsed() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {\n    func one() {}\n    func two() {}\n}\n", to: Self.path, in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["update-index", "--assume-unchanged", Self.path], in: root)
        try Data([0xFF, 0xFE, 0xFF, 0xFF]).write(to: root.appendingPathComponent(Self.path))

        let freshness = try await engine.ensureFresh()
        let answer = try engine.measuredDigest(targets: [Self.path], options: DigestOptions())
        let header = freshness.noting(reparsed: answer.reparsedPaths, unreparsed: answer.unreparsedPaths).headerLine

        #expect(answer.reparsedPaths.isEmpty)
        #expect(answer.unreparsedPaths == [Self.path])
        #expect(!header.contains("reparsed from the live"))
        #expect(header.contains("dirty: 0 (+1 not in git status, could not be reparsed: \(Self.path))  parse_errors:"))
    }

    /// A header naming both kinds keeps each file under the clause that is true of it.
    @Test
    func theHeaderNamesReparsedAndUnreparsedFilesApart() {
        let freshness = Freshness(tree: WorkingTree(repository: "repo"), headShort: "abc1234", dirtyCount: 0, parseErrorFiles: 0)
            .noting(reparsed: ["A.swift"], unreparsed: ["B.swift"])

        #expect(freshness.headerLine.contains("dirty: 0 (+2 not in git status, reparsed from the live file: A.swift; could not be reparsed: B.swift)  parse_errors:"))
    }
}
