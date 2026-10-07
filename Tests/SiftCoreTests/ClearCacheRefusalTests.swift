//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift reset` and `sift uninstall --purge` delete `.sift/` through one path, which refuses a `.sift` that is not the directory the tool made.
@Suite(.temporaryDirectories)
struct ClearCacheRefusalTests {
    @Test
    func aSymlinkedCacheIsRefusedAndNothingIsWrittenThroughIt() throws {
        let scratch = try TemporaryDirectory.make("clear-cache-link")
        let root = scratch.appendingPathComponent("repository")
        let precious = scratch.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: SiftPaths.cache(in: root), withDestinationURL: precious)

        #expect(throws: PathKind.Refused.self) {
            try SetAsideSession.clearCache(in: root)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: precious.path) == ["a.txt"])
    }

    @Test
    func aCacheSwappedForALinkWhileTheLockIsTakenIsRefusedAndNothingIsDeletedThroughIt() throws {
        let (root, precious) = try Self.cacheAndPrecious("clear-cache-swap-link")
        let cache = SiftPaths.cache(in: root)

        #expect(throws: PathKind.Refused.self) {
            try SetAsideSession.clearCache(in: root) {
                try? FileManager.default.moveItem(at: cache, to: root.appendingPathComponent("moved"))
                try? FileManager.default.createSymbolicLink(at: cache, withDestinationURL: precious)
            }
        }

        #expect(PathKind.of(cache) == .symlink(precious.path))
        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("a.txt").path))
    }

    @Test
    func aCacheSwappedForAnotherDirectoryWhileTheLockIsTakenIsRefusedAndNothingIsDeleted() throws {
        let (root, precious) = try Self.cacheAndPrecious("clear-cache-swap-directory")
        let cache = SiftPaths.cache(in: root)

        #expect(throws: PathKind.Refused.self) {
            try SetAsideSession.clearCache(in: root) {
                try? FileManager.default.moveItem(at: cache, to: root.appendingPathComponent("moved"))
                try? FileManager.default.moveItem(at: precious, to: cache)
            }
        }

        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.txt").path))
    }

    /// A repository with a plain `.sift`, and beside it a directory holding `a.txt` that a swap can put in its place.
    private static func cacheAndPrecious(_ name: String) throws -> (root: URL, precious: URL) {
        let scratch = try TemporaryDirectory.make(name)
        let root = scratch.appendingPathComponent("repository")
        let precious = scratch.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: root), withIntermediateDirectories: true)
        try "index".write(to: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        return (root, precious)
    }
}
