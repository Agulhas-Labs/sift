//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the order of a resumed first build: the resolution stamp is written before the parse, not after it (Docs/Design.md §6.9).
///
/// A resumed attempt stopped at its first batch boundary never reaches its head, so a stamp found afterwards can only have been written ahead of the parse.
@Suite(.temporaryDirectories)
struct ResumedStampBeforeParseTests {
    /// More files than two of the indexer's batches of a hundred, so a build stopped at the first boundary leaves work on both sides of it.
    private static let fileCount = 250

    /// Runs a first query's build in a task cancelled before it starts, which stops it at its first batch boundary.
    private static func cancelledBuild(at root: URL, sourceLocation: SourceLocation = #_sourceLocation) async {
        await #expect(throws: CancellationError.self, sourceLocation: sourceLocation) {
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await SiftEngine(directory: root).ensureFresh()
            }.value
        }
    }

    @Test
    func aResumedBuildStoppedAtItsFirstBatchHoldsTheStampButNoHead() async throws {
        let root = try TestSources.makeTempRepo()
        for index in 0 ..< Self.fileCount {
            try TestSources.write("struct Item\(index) { let one = 1 }\n", to: "Sources/App/Item\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")

        await Self.cancelledBuild(at: root)
        let abandoned = try SiftEngine(directory: root).store
        #expect(try abandoned.fileInventory().isEmpty == false)

        await Self.cancelledBuild(at: root)

        let store = try SiftEngine(directory: root).store
        #expect(try store.metaValue("indexed_head") == nil)
        #expect(try store.metaValue("resolution_fingerprint") == ReadOnlyIndex.resolutionFingerprint(atRoot: root.path))
    }
}
