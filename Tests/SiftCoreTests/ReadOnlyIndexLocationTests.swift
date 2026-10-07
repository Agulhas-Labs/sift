//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Whether a tree's index would be held in memory is told without opening an engine and without making `.sift/`, so a caller that then declines leaves the tree as it found it.
@Suite(.temporaryDirectories)
struct ReadOnlyIndexLocationTests {
    /// A writable tree with no `.sift/` would keep its index on disk, and asking makes no `.sift/` there.
    @Test
    func askingAboutAWritableTreeMakesNothingInIt() throws {
        let root = try ReadOnlyTree.seed()

        #expect(!SiftEngine.wouldKeepIndexInMemory(root: root))
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
    }

    /// A tree nobody may write would keep it in memory, whether `.sift/` was never made or was made before the tree went read-only.
    @Test
    func aTreeNobodyMayWriteWouldKeepItInMemory() async throws {
        let bare = try ReadOnlyTree.make()
        defer { ReadOnlyTree.restore(bare) }
        let indexed = try ReadOnlyTree.seed()
        try await SiftEngine(directory: indexed).ensureFresh()
        try ReadOnlyTree.chmod("a-w", indexed)
        defer { ReadOnlyTree.restore(indexed) }

        #expect(SiftEngine.wouldKeepIndexInMemory(root: bare))
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: bare).path))
        #expect(SiftEngine.wouldKeepIndexInMemory(root: indexed))
    }
}
