//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A tree that already has an index store but cannot be written cannot keep the semantic cache either, and the note saying so names that, not the platform's words about a file.
@Suite(.temporaryDirectories)
struct ReadOnlyStoreNoteTests {
    @Test
    func aStoreThatFailsToOpenForWantOfACacheNamesTheCauseInOneLine() async throws {
        let root = try ReadOnlyTree.seed()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let unit = root.appendingPathComponent(".build/out/v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: unit)
        try ReadOnlyTree.chmod("a-w", root)
        defer { ReadOnlyTree.restore(root) }
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "Depot", freshness: freshness)
        let note = try #require(answer.split(separator: "\n").first { $0.contains("but failed to open:") }.map(String.init))

        #expect(note.contains("cannot be written"), "\(note)")
        #expect(!note.contains("permission"), "\(note)")
        #expect(!note.contains("Error Domain"), "\(note)")
    }

    @Test
    func anInTreeStoreThatFailsToOpenForWantOfACacheNamesTheCauseInOneLine() async throws {
        let root = try ReadOnlyTree.seed()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        let unit = root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore/v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: unit)
        try ReadOnlyTree.chmod("a-w", root)
        defer { ReadOnlyTree.restore(root) }
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "Depot", freshness: freshness)
        let note = try #require(answer.split(separator: "\n").first { $0.contains("in-tree store .build/runner-dd failed to open:") }.map(String.init))

        #expect(note.contains("cannot be written"), "\(note)")
        #expect(!note.contains("permission"), "\(note)")
        #expect(!note.contains("Error Domain"), "\(note)")
    }
}
