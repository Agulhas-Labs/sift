//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the sibling probe's single-file answer against a store whose first build was stopped partway.
@Suite(.temporaryDirectories)
struct PartialStoreDeclaringFileTests {
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
    func aStoreNoBuildHasFinishedNamesNoFileUntilTheBuildCompletes() async throws {
        let root = try TestSources.makeTempRepo()
        // The twin is declared again in the last file listed, which a build stopped at its first batch has not reached.
        try TestSources.write("struct Twin { let one = 1 }\nstruct Solo { let one = 1 }\n", to: "Sources/App/Early.swift", in: root)
        try TestSources.write("struct Twin { let two = 2 }\n", to: "Sources/App/Late.swift", in: root)
        for index in 0 ..< 250 {
            try TestSources.write("struct Item\(index) { let one = 1 }\n", to: "Sources/App/Item\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")

        await Self.cancelledBuild(at: root)
        let partial = try SiftEngine(directory: root).store.fileInventory()
        #expect(partial["Sources/App/Early.swift"] != nil)
        #expect(partial["Sources/App/Late.swift"] == nil)
        #expect(!ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        #expect(SiblingIndexProbe.declaringFile(named: "Twin", atRoot: root.path) == nil)
        #expect(SiblingIndexProbe.declaringFile(named: "Solo", atRoot: root.path) == nil)

        try await SiftEngine(directory: root).ensureFresh()

        #expect(ReadOnlyIndex.hasUsableIndex(atRoot: root.path))
        #expect(SiblingIndexProbe.declaringFile(named: "Twin", atRoot: root.path) == nil)
        #expect(SiblingIndexProbe.declaringFile(named: "Solo", atRoot: root.path) == "Sources/App/Early.swift")
    }
}
