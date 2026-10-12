//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the stamp that lets a resumed first build bring its stored rows under the current resolver once rather than on every attempt (Docs/Design.md §6.9).
///
/// An attempt that stored every row and was stopped before its head is reproduced by running the indexer's resumed build without marking it done. One row's module is then overwritten by hand, a marker the re-attribution pass would erase, so whether the next attempt ran that pass reads straight off the row.
@Suite(.temporaryDirectories)
struct ResumedResolutionStampTests {
    private static let fileCount = 150
    /// The meta key the stamp is kept under, spelled out so the suite builds against an indexer that names no stamp.
    private static var stampKey: String {
        "resolution_fingerprint"
    }

    private static var marker: String {
        "Depot"
    }

    /// A committed repository of `fileCount` small files and the engine opened on it.
    private static func makeEngine() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for index in 0 ..< fileCount {
            try TestSources.write("struct Item\(index) { let one = 1 }\n", to: "Sources/App/Item\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")
        return try SiftEngine(directory: root)
    }

    /// The indexer a fresh process would build over the engine's store and root.
    private static func indexer(over engine: SiftEngine) throws -> Indexer {
        let root = engine.repoRoot
        let config = try SiftConfig.load(repoRoot: root)
        let git = GitContext(repoRoot: root)
        return Indexer(
            repoRoot: root,
            store: engine.store,
            enumerator: FileEnumerator(repoRoot: root, config: config, gitListing: { try git.visibleSwiftFiles() }),
            resolver: ModuleResolver(repoRoot: root, config: config)
        )
    }

    /// Stores every row through a resumed build that never reaches its head, then overwrites one row's module with the marker, and returns that row's path.
    private static func convergedWithoutHead(_ engine: SiftEngine, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        try await indexer(over: engine).fullIndex(storeBuiltAt: { nil }, resuming: true)
        #expect(try engine.store.metaValue("indexed_head") == nil, sourceLocation: sourceLocation)
        let inventory = try engine.store.fileInventory()
        #expect(inventory.count == fileCount, sourceLocation: sourceLocation)
        let marked = try #require(inventory.keys.min(), sourceLocation: sourceLocation)
        _ = try engine.store.reattributeModules { path in
            path == marked ? (marker, false) : (inventory[path]?.module ?? "", inventory[path]?.moduleGuessed ?? true)
        }
        return marked
    }

    @Test
    func aStampTheResolverMatchesSkipsReattributionAndTheNextAttemptWritesTheHead() async throws {
        let engine = try Self.makeEngine()
        let marked = try await Self.convergedWithoutHead(engine)
        let before = try engine.store.fileInventory()
        #expect(try engine.store.metaValue(Self.stampKey) == ReadOnlyIndex.resolutionFingerprint(atRoot: engine.repoRoot.path))

        try await engine.ensureFresh()

        let after = try engine.store.fileInventory()
        #expect(try engine.store.metaValue("indexed_head") != nil)
        #expect(after[marked]?.module == Self.marker, "the kept rows were re-attributed under a stamp that already vouched for them")
        #expect(before.allSatisfy { path, row in after[path]?.id == row.id })
    }

    @Test
    func aStampTheResolverDoesNotMatchIsMadeTrueByReattributingTheKeptRows() async throws {
        let engine = try Self.makeEngine()
        let marked = try await Self.convergedWithoutHead(engine)
        try engine.store.setMetaValue("v0:written-by-another-resolver", forKey: Self.stampKey)

        try await engine.ensureFresh()

        let after = try engine.store.fileInventory()

        #expect(after[marked]?.module != Self.marker)
        #expect(after[marked]?.module == after.values.first { $0.module != Self.marker }?.module)
        #expect(try engine.store.metaValue(Self.stampKey) == ReadOnlyIndex.resolutionFingerprint(atRoot: engine.repoRoot.path))
    }

    @Test
    func aRebuildStoppedPartwayLeavesNoStampItsResolverDoesNotMatch() async throws {
        let engine = try Self.makeEngine()
        try await engine.ensureFresh()
        try engine.store.setMetaValue("v0:written-by-another-resolver", forKey: Self.stampKey)

        await #expect(throws: CancellationError.self) {
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await engine.fullIndex()
            }.value
        }

        #expect(try engine.store.metaValue("indexed_head") != nil)
        #expect(try engine.store.metaValue(Self.stampKey) == "")
    }
}
