//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` with nothing built: every changed file is walked to its call sites from the declarations the diff touched in it, never from every declaration of the file.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNoStoreTouchedTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    private static var gizmo: String {
        """
        public struct Gizmo {
            public init() {}
            public func spin() -> Int { 1 }
            public func idle() -> Int { 0 }
        }
        """
    }

    private static var suites: String {
        """
        import Testing
        @testable import Lib

        struct GizmoTests {
            @Test func spins() { #expect(Gizmo().spin() == 2) }
        }

        struct BystanderTests {
            @Test func idles() { #expect(Gizmo().idle() == 0) }
        }
        """
    }

    /// The `affected` answer for an uncommitted edit to one member of `Gizmo`, in a package nothing has built.
    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write(gizmo, to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write(suites, to: "Tests/LibTests/LibTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(gizmo.replacingOccurrences(of: "func spin() -> Int { 1 }", with: "func spin() -> Int { 2 }"), to: "Sources/Lib/Gizmo.swift", in: root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(depth: 1), freshness: freshness)
    }

    /// One fixture for the three rules.
    @Test
    func withNoStoreTheWalkStartsFromTheTouchedDeclarations() async throws {
        let output = try await Self.answer()

        // The touched member's test is reached; a test calling only an untouched member of the same file is not.
        #expect(output.contains("LibTests.GizmoTests/spins() — 1 hop, name match"))
        #expect(!output.contains("BystanderTests"))
        // The file's line says how many of its declarations the diff touched.
        #expect(output.contains("  Sources/Lib/Gizmo.swift — added or modified, 1 of 4 declarations touched"))
        // The headline names the call-site walk, not the after-edit walk, since nothing was built.
        #expect(output.contains("a call-site walk from the declarations the diff touched (syntactic, lower bound)"))
        #expect(!output.contains("the after-edit walk"))
    }

    /// The limits topic and `diff`'s clause say what the walk starts from.
    @Test
    func theLimitsTopicAndDiffsClauseNameTheTouchedDeclarations() {
        #expect(AffectedHelpTopic.body.contains("- a changed file counts the declarations the diff touched in it, read by comparing both sides' parses; a file the comparison cannot account for counts whole, and the answer names it"))
        let tests = AffectedRenderer.Output(body: "", axis: .syntacticOnly, reached: [], limitCount: 0, depth: 2, walkedOn: 0, walkedTo: 0, newerFiles: [])
        let range = DiffRange(from: "HEAD", to: .workingTree, described: "working tree vs HEAD")
        let lines = DiffRenderer.render(DiffRenderer.Input(
            range: range,
            files: [],
            notBrokenDown: [],
            nonSwift: [],
            callers: [],
            workingTreeIsAfterSide: true,
            tests: tests,
            options: DiffOptions(range: range),
            rawDiffBytes: 0,
            axis: .syntacticOnly
        )).body
        #expect(lines.contains("from `sift affected`: the declarations the diff touched in each changed file (every declaration of a file the answer names as seeded whole), followed 2 hops"))
    }
}
