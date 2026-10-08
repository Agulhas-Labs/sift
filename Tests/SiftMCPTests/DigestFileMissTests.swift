//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A file target that matches no indexed file served nothing, so the shared definition reads it as a miss — the usage log marks it, and nothing that credits a digest credits it.
@Suite(.temporaryDirectories)
struct DigestFileMissTests {
    private static func answer(_ target: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        return try engine.digest(target: target, options: DigestOptions())
    }

    @Test
    func aFileTargetThatMatchesNoIndexedFileIsAMiss() async throws {
        let root = try ListedWideWindowTests.repository()
        let answer = try await Self.answer("Nowhere/Missing.swift", in: root)

        #expect(answer.contains(DigestMiss.noIndexedFilePrefix), "\(answer)")
        #expect(DigestMiss.isMiss(inAnswer: answer), "\(answer)")
    }

    @Test
    func aBasenameSeveralFilesShareIsAMissThatServesNone() {
        let answer = """
        no indexed file matches Old/View.swift — 2 indexed files share that basename; digest one of these exact targets:
          digest Sources/A/View.swift
          digest Sources/B/View.swift
        """

        #expect(DigestMiss.isMiss(inAnswer: answer))
    }

    @Test
    func aServedFileIsStillNotAMiss() async throws {
        let root = try ListedWideWindowTests.repository()
        let served = try await Self.answer("Ledger", in: root)

        #expect(!DigestMiss.isMiss(inAnswer: served))
    }
}
