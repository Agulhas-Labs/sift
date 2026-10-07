//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
@testable import SiftCore
import Testing

/// Covers the reconcile backstop: convergence regardless of how the tree changed, and zero-work on a clean one.
@Suite(.temporaryDirectories)
struct ReconcileTests {
    @Test
    func untouchedTreeReconcilesToZeroChanges() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let result = try await engine.reconcile()

        #expect(result.removed == 0)
        #expect(result.reindexed == 0)
    }

    /// A byte-order mark is dropped by decoding, so a size or hash taken over the decoded text never matches the file on disk — and the reconcile compares against the file on disk.
    @Test
    func aFileWithAByteOrderMarkReconcilesToZeroChanges() async throws {
        let root = try TestSources.makeTempRepo()
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("struct Alpha {}\n".utf8)
        let url = root.appendingPathComponent("Sources/App/Alpha.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let result = try await engine.reconcile()

        #expect(result.reindexed == 0)
    }

    /// The property behind the one above, asserted directly: the recorded size and hash are of the bytes on disk.
    @Test
    func theParserRecordsTheSizeAndHashOfTheRawBytes() throws {
        let directory = try TestSources.makeTempDirectory()
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("struct Alpha {}\n".utf8)
        let url = directory.appendingPathComponent("Alpha.swift")
        try bytes.write(to: url)

        let parsed = try #require(FileParser.parse(absoluteURL: url, repoRelativePath: "Alpha.swift"))

        #expect(parsed.size == bytes.count)
        #expect(parsed.contentHash == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    @Test
    func reconcileConvergesAfterOutOfBandChanges() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.write("struct Beta {}\n", to: "Sources/App/Beta.swift", in: root)
        try TestSources.commitAll(in: root, message: "add types")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/App/Beta.swift"))
        try TestSources.write("struct Gamma {}\n", to: "Sources/App/Gamma.swift", in: root)

        let result = try await engine.reconcile()
        let gamma = try engine.digest(target: "Gamma", options: DigestOptions())
        let beta = try engine.digest(target: "Beta", options: DigestOptions())

        #expect(result.removed == 1)
        #expect(result.reindexed == 1)
        #expect(gamma.contains("struct Gamma"))
        #expect(beta.contains("no symbol named Beta") || beta.contains("nearest symbols"))
    }
}
