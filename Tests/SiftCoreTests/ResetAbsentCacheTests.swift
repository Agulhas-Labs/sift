//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `reset` names the directory it removed only when there was one, so a repository without a cache is never told one was deleted.
@Suite(.temporaryDirectories)
struct ResetAbsentCacheTests {
    @Test
    func aRepositoryWithoutACacheResetsToNothingRemoved() throws {
        let root = try TemporaryDirectory.make("reset-absent")

        let reset = try RootDiscovery.$current.withValue(RootDiscovery { $0 }) {
            try SiftEngine.reset(directory: root)
        }

        #expect(reset.removed == nil)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
    }

    @Test
    func aRepositoryWithACacheResetsToItsName() throws {
        let root = try TemporaryDirectory.make("reset-present")
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: root), withIntermediateDirectories: true)

        let reset = try RootDiscovery.$current.withValue(RootDiscovery { $0 }) {
            try SiftEngine.reset(directory: root)
        }

        #expect(reset.removed == SiftPaths.directoryName)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).path))
    }
}
