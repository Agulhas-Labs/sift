//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A checkout nobody may write — a vendored package, a read-only mount — answers without making `.sift/` in it.
@Suite(.temporaryDirectories)
struct ReadOnlyTreeTests {
    /// The four working-tree reads open no index, so nothing about the store may stop them, and none leaves a `.sift/` behind.
    @Test
    func theLiveReadsAnswerInATreeNobodyMayWrite() async throws {
        let root = try ReadOnlyTree.make()
        defer { ReadOnlyTree.restore(root) }

        let engine = try SiftEngine(directory: root)
        let answers = try await [
            engine.strings(query: "depot"),
            engine.dupes(scope: []),
            engine.similar(target: "Depot.save"),
            engine.search(query: "kind:struct"),
        ]

        #expect(answers[0].contains("Sources/Depot.swift"), "\(answers[0])")
        #expect(answers[3].contains("Depot"), "\(answers[3])")
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
        for answer in answers {
            #expect(answer.hasPrefix("tree: "), "\(answer)")
            #expect(answer.contains("source: working tree, read live"), "\(answer)")
        }
    }

    /// A `.sift/` made before the tree went read-only is not opened for writing: the index goes to memory, still sees what changed since, and the file is left as it was.
    @Test
    func anIndexMadeBeforeTheTreeWentReadOnlyIsLeftAlone() async throws {
        let root = try ReadOnlyTree.seed()
        try await SiftEngine(directory: root).ensureFresh()
        let index = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName)
        let before = try Data(contentsOf: index)
        try TestSources.write("struct Bin {}\n", to: "Sources/Bin.swift", in: root)
        try ReadOnlyTree.chmod("a-w", root)
        defer { ReadOnlyTree.restore(root) }

        #expect(try IndexLocation.resolve(databasePath: index.path) == .memory)
        let engine = try SiftEngine(directory: root)
        #expect(try engine.strings(query: "depot").contains("Sources/Depot.swift"))
        let freshness = try await engine.ensureFresh()
        #expect(freshness.dirtyCount == 1)
        #expect(try engine.digest(target: "Bin", options: DigestOptions()).contains("Sources/Bin.swift"))
        #expect(try Data(contentsOf: index) == before)
    }

    /// `digest`, `where` and `status` answer from the index in memory and say so under the header; `status` names no size for a file that is not there.
    @Test
    func theStoredAnswersSayTheirIndexIsInMemory() async throws {
        let root = try ReadOnlyTree.make()
        defer { ReadOnlyTree.restore(root) }
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let digest = try freshness.headerLine + "\n" + engine.measuredDigest(targets: ["Depot"], options: DigestOptions()).text
        let lookup = try await engine.lookup(symbol: "Depot", freshness: freshness)
        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("db: in memory (this tree cannot be written)"), "\(status)")
        #expect(!status.contains(" MB"), "\(status)")
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
        for answer in [digest, lookup] {
            let lines = answer.split(separator: "\n").map(String.init)
            #expect(lines.first?.hasPrefix("tree: ") == true, "\(answer)")
            #expect(lines.dropFirst().first == SiftEngine.inMemoryIndexNote, "\(answer)")
            #expect(answer.contains("Sources/Depot.swift"), "\(answer)")
        }
    }

    /// A tree that can be written keeps its index on disk, and its answers carry no such note.
    @Test
    func aWritableTreeSaysNothingAboutMemory() async throws {
        let root = try ReadOnlyTree.seed()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let digest = try engine.digest(target: "Depot", options: DigestOptions())
        let lookup = try await engine.lookup(symbol: "Depot", freshness: freshness)
        let status = try engine.statusText(freshness: freshness)

        #expect(!digest.contains(SiftEngine.inMemoryIndexNote))
        #expect(!lookup.contains(SiftEngine.inMemoryIndexNote))
        #expect(!status.contains("db: in memory"), "\(status)")
    }

    /// A failure to make `.sift/` that is not about permission is still thrown rather than answered around.
    @Test
    func onlyAPermissionRefusalSendsTheIndexToMemory() throws {
        let root = try TestSources.makeTempDirectory()
        let blocker = root.appendingPathComponent("blocker")
        try Data("a file where a directory would go\n".utf8).write(to: blocker)

        #expect(throws: (any Error).self) {
            try IndexLocation.resolve(databasePath: blocker.appendingPathComponent("cache/index.db").path)
        }
        #expect(IndexLocation.isPermissionRefusal(CocoaError(.fileWriteNoPermission)))
        #expect(IndexLocation.isPermissionRefusal(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))))
        #expect(!IndexLocation.isPermissionRefusal(CocoaError(.fileWriteOutOfSpace)))
    }
}
