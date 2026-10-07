//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an edit made after the build whose mtime is put back to before it: the semantic axis still reads the file as written since the build, because the row records a moment `touch -r` cannot restore.
@Suite(.temporaryDirectories)
struct RestoredMtimeFreshnessTests {
    private static var path: String {
        "Sources/App/Alpha.swift"
    }

    /// The edit reads as modified on the query that reparses it and on every later one, while the file it restored the mtime of had read as live before the edit.
    @Test
    func anEditWithItsMtimeRestoredReadsAsModifiedSinceTheBuild() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: Self.path, in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        // The build lands after the index read the file, as a build after a clean checkout does.
        let anchor = SemanticContext.buildAnchor(newestUnit: Date())
        try await Task.sleep(for: .milliseconds(20))
        let beforeTheEdit = Self.probe(root: root, store: engine.store, anchor: anchor).state(of: Self.absolute(in: root))

        try Self.rewriteRestoringMtime("struct Gamma {}\n", in: root)
        _ = try await engine.ensureFresh()
        let onTheReparse = Self.probe(root: root, store: engine.store, anchor: anchor).state(of: Self.absolute(in: root))
        _ = try await engine.ensureFresh()
        let onTheNextQuery = Self.probe(root: root, store: engine.store, anchor: anchor).state(of: Self.absolute(in: root))

        #expect(beforeTheEdit == .live)
        #expect(try engine.digest(target: "Gamma", options: DigestOptions()).contains("struct Gamma"))
        #expect(onTheReparse == .modifiedSinceBuild)
        #expect(onTheNextQuery == .modifiedSinceBuild)
    }

    private static func probe(root: URL, store: IndexStore, anchor: Double) -> OccurrenceFreshness {
        OccurrenceFreshness(store: store, buildAnchor: anchor) { absolute in
            let prefix = root.standardizedFileURL.path + "/"
            return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : absolute
        }
    }

    private static func absolute(in root: URL) -> String {
        root.standardizedFileURL.path + "/" + path
    }

    /// Writes `text` over the fixture file and puts its mtime back, as `touch -r` would, and requires that size and mtime really are what they were.
    private static func rewriteRestoringMtime(_ text: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = root.appendingPathComponent(path)
        let original = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try #require(original[.modificationDate] as? Date, sourceLocation: sourceLocation)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let rewritten = try FileManager.default.attributesOfItem(atPath: url.path)
        try #require(rewritten[.size] as? Int64 == original[.size] as? Int64, sourceLocation: sourceLocation)
        let restored = try #require(rewritten[.modificationDate] as? Date, sourceLocation: sourceLocation)
        try #require(abs(restored.timeIntervalSince1970 - modified.timeIntervalSince1970) < 0.0001, sourceLocation: sourceLocation)
    }
}
