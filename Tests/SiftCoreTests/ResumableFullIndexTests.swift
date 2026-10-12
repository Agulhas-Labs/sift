//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a first build abandoned partway: what it stored is kept, the next attempt parses only the rest, and nothing it left reads as a finished index (Docs/Design.md §6.9).
///
/// The interruption is a cancelled task, which stops the build at a batch boundary the way a killed hook process stops it wherever it stands. A row the resumed build kept still carries the id it was stored under, since a parse replaces a file's row by delete-then-insert: that is the parse counter here.
@Suite(.temporaryDirectories)
struct ResumableFullIndexTests {
    /// More files than two of the indexer's batches of a hundred, so a build stopped at the first boundary leaves work on both sides of it.
    ///
    /// A literal, so the suite builds against an indexer that has no batch size to name.
    private static let fileCount = 250

    private static func source(_ index: Int, typeName: String = "Item") -> String {
        "struct \(typeName)\(index) { let one = 1 }\n"
    }

    private static func makeRepo(under directory: String = "Sources/App") throws -> URL {
        let root = try TestSources.makeTempRepo()
        for index in 0 ..< fileCount {
            try TestSources.write(source(index), to: "\(directory)/Item\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")
        return root
    }

    /// Runs the first query's build in a task cancelled before it starts, which must stop it partway, and returns the rows it stored.
    private static func interruptedBuild(at root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: FileRow] {
        await #expect(throws: CancellationError.self, sourceLocation: sourceLocation) {
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await SiftEngine(directory: root).ensureFresh()
            }.value
        }
        let store = try SiftEngine(directory: root).store
        #expect(try store.metaValue("indexed_head") == nil, sourceLocation: sourceLocation)
        return try store.fileInventory()
    }

    /// What a row holds apart from its id and change moment, which differ between two builds of the same tree.
    private static func content(of store: IndexStore) throws -> [String: String] {
        try store.fileInventory().mapValues { row in
            "\(row.size) \(row.contentHash) \(row.module) \(row.moduleGuessed) \(row.imports) \(row.parseErrorCount)"
        }
    }

    /// An uninterrupted build of the same tree, held in memory so it touches nothing on disk.
    private static func referenceBuild(of root: URL) async throws -> (content: [String: String], symbols: Int) {
        let reference = try SiftEngine(directory: root, storesNothing: true)
        try await reference.ensureFresh()
        return try (content(of: reference.store), reference.store.counts().symbols)
    }

    @Test
    func anInterruptedBuildIsResumedParsingOnlyTheFilesItDidNotStore() async throws {
        let root = try Self.makeRepo()
        let interrupted = try await Self.interruptedBuild(at: root)
        #expect(!interrupted.isEmpty)
        #expect(interrupted.count < Self.fileCount)

        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        let resumed = try engine.store.fileInventory()

        let rewritten = interrupted.filter { path, row in resumed[path]?.id != row.id }.keys.sorted()
        #expect(rewritten.isEmpty, "rows the interrupted build stored were parsed again: \(rewritten.prefix(5))")
        #expect(resumed.count == Self.fileCount)
        #expect(try engine.store.metaValue("indexed_head") != nil)
        #expect(ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        let reference = try await Self.referenceBuild(of: root)
        #expect(try Self.content(of: engine.store) == reference.content)
        #expect(try engine.store.counts().symbols == reference.symbols)
    }

    @Test
    func aPartialIndexIsNotUsableAndAFileChangedSinceIsParsedAgain() async throws {
        let root = try Self.makeRepo()
        let interrupted = try await Self.interruptedBuild(at: root)
        #expect(!ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        let changedPath = try #require(interrupted.keys.sorted().first)
        let index = try #require(Int(changedPath.dropFirst("Sources/App/Item".count).dropLast(".swift".count)))
        // The same size, so only the content hash tells the stored row is stale.
        try TestSources.write(Self.source(index, typeName: "Ware"), to: changedPath, in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        let resumed = try engine.store.fileInventory()

        #expect(resumed[changedPath]?.id != interrupted[changedPath]?.id)
        #expect(resumed[changedPath]?.size == interrupted[changedPath]?.size)
        let rewritten = interrupted.filter { path, row in path != changedPath && resumed[path]?.id != row.id }.keys
        #expect(rewritten.isEmpty)
        #expect(try engine.digest(target: "Ware\(index)", options: DigestOptions()).contains("struct Ware\(index)"))
        let reference = try await Self.referenceBuild(of: root)
        #expect(try engine.store.counts().symbols == reference.symbols)
    }

    @Test
    func rowsKeptFromAnInterruptedBuildTakeTheModuleTheCurrentManifestGives() async throws {
        let root = try Self.makeRepo(under: "Linter/Sources/Linter")
        let interrupted = try await Self.interruptedBuild(at: root)
        #expect(interrupted.values.contains { $0.moduleGuessed })
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "VendorTools",
                targets: [
                    .executableTarget(name: "Linter", path: "Linter/Sources/Linter"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )

        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()

        let resumed = try engine.store.fileInventory()

        #expect(interrupted.allSatisfy { path, row in resumed[path]?.id == row.id })
        #expect(interrupted.keys.allSatisfy { resumed[$0]?.moduleGuessed == false })
        let reference = try await Self.referenceBuild(of: root)
        #expect(try Self.content(of: engine.store) == reference.content)
    }
}
