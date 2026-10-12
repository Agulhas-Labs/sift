//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A search of a whole indexed repository passes over sift's own binary database as the shell's `ugrep` does under `-I`, so the store below every indexed root never leaves a search undecided.
@Suite(.temporaryDirectories)
struct SweepPastSiftStoreTests {
    /// A tree holding a source file and a cache directory whose database file holds `database` and whose build directory holds a text note, each naming the type.
    private static func tree(database: String) throws -> URL {
        let root = try TemporaryDirectory.make("store-walk").appendingPathComponent("store-walk")
        let cache = root.appendingPathComponent(SiftPaths.directoryName)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("without-build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data(database.utf8).write(to: cache.appendingPathComponent(SiftPaths.indexFileName))
        try Data("Depot\n".utf8).write(to: cache.appendingPathComponent("without-build/notes.txt"))
        try Data("let Depot = 1\n".utf8).write(to: root.appendingPathComponent("Sources/A.swift"))
        return root
    }

    /// The files of the lines a search of `.` for the type prints in `root`, below the root, whatever the shape weighing it.
    private static func printedFiles(in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [[String]] {
        try [false, true].map { skipsCache in
            let measured = try #require(ShellGrep(arguments: ["-rn", "Depot", "."]), sourceLocation: sourceLocation).measured(in: root.path, skipsCache: skipsCache)
            guard case let .printed(lines) = measured.outcome else {
                Issue.record("expected the search worked out, got \(measured.outcome)", sourceLocation: sourceLocation)
                return []
            }
            // The walk spells the root as the file system does, so the path below it is cut at the root's own name.
            return lines.map { $0.file.components(separatedBy: "/store-walk/").last ?? $0.file }
        }
    }

    /// The database opens on a NUL, as every one of sift's does, so `ugrep` prints nothing from it and the search is worked out from the rest; the text note beside it is read wherever the cache is not skipped.
    @Test
    func aDatabaseOpeningOnANulIsPassedOverByEverySearch() throws {
        let root = try Self.tree(database: "SQLite format 3\u{0}Depot\n")

        #expect(try Self.printedFiles(in: root) == [[".sift/without-build/notes.txt", "Sources/A.swift"], ["Sources/A.swift"]])
    }

    /// A file named as the database that opens as text is one `ugrep` prints from, so a search that weighs the cache reads it.
    @Test
    func aDatabaseNameOpeningOnTextIsStillRead() throws {
        let root = try Self.tree(database: "Depot\n")

        #expect(try Self.printedFiles(in: root) == [[".sift/index.db", ".sift/without-build/notes.txt", "Sources/A.swift"], ["Sources/A.swift"]])
    }

    /// The reviewed case end to end: a word-anchored sweep of a whole indexed repository whose last commit message names the type is answered in place with every line it prints, from the root and from inside `.git` alike, where the store once left it withheld.
    @Test
    func aSweepOfAnIndexedRepositoryIsAnsweredPastItsStore() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()
        try Data("Gizmo lands\n".utf8).write(to: root.appendingPathComponent(".git/COMMIT_EDITMSG"))
        try await SiftEngine(directory: root, registry: nil).ensureFresh()
        #expect(FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path))

        let fromRoot = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gizmo .", in: root))
        let fromGit = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gizmo ..", in: root.appendingPathComponent(".git")))

        // Every line the shell's grep prints is a code use, so the sweep is proven rather than handed to the loose reading.
        for answered in [fromRoot, fromGit] {
            #expect(answered.calls.map(\.target) == ["Gizmo"])
            #expect(answered.reason.split(separator: "\n").first?.contains("`where Gizmo (refs: true)`") == true)
            #expect(!answered.reason.contains("Gizmo lands"))
        }
    }
}
