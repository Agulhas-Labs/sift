//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a build that resumes a partial store after the tree moved on: a stored file deleted, renamed or made unreadable between the two attempts leaves no row behind.
@Suite(.temporaryDirectories)
struct ResumedStoreConvergenceTests {
    /// More files than two of the indexer's batches of a hundred, so a build stopped at the first boundary leaves work on both sides of it.
    private static let fileCount = 250

    /// Runs a first query's build in a task cancelled before it starts, which stops it at its first batch boundary, and returns what it stored.
    private static func cancelledBuild(at root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: FileRow] {
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

    @Test
    func aDeletedRenamedAndUnreadableStoredFileLeaveNoStaleRowAfterTheResume() async throws {
        let root = try TestSources.makeTempRepo()
        var every: Set<String> = []
        for index in 0 ..< Self.fileCount {
            let path = "Sources/App/Item\(index).swift"
            every.insert(path)
            try TestSources.write("struct Item\(index) { let one = 1 }\n", to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")

        let interrupted = try await Self.cancelledBuild(at: root)
        let stored = interrupted.keys.sorted()
        try #require(stored.count >= 3)
        #expect(stored.count < Self.fileCount)
        let deleted = stored[0]
        let renamed = stored[1]
        let unreadable = stored[2]
        let moved = "Sources/App/Moved.swift"
        try FileManager.default.removeItem(at: root.appendingPathComponent(deleted))
        try FileManager.default.moveItem(at: root.appendingPathComponent(renamed), to: root.appendingPathComponent(moved))
        // Bytes that are not UTF-8: listed by git, read, and never parsed.
        try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: root.appendingPathComponent(unreadable))
        try TestSources.commitAll(in: root, message: "move on")

        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        let resumed = try engine.store.fileInventory()

        let expected = every.subtracting([deleted, renamed, unreadable]).union([moved])
        #expect(Set(resumed.keys) == expected)
        #expect(try engine.store.metaValue("indexed_head") != nil)

        let reference = try SiftEngine(directory: root, storesNothing: true)
        try await reference.ensureFresh()
        #expect(try Set(reference.store.fileInventory().keys) == expected)
        #expect(try engine.store.counts().symbols == reference.store.counts().symbols)
    }
}
