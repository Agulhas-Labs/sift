//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the shape `affected` gives a target whose every test is affected next to one only partly affected: the whole target is one line with its count and the commands that run it, and the partial target gets the commands that run exactly its affected suites, with no rows and no suite list.
///
/// No build: the name-match fallback reaches these tests, which is all the output's shape needs.
@Suite(.temporaryDirectories)
struct AffectedWholeTargetLineTests {
    private static func manifest() -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
                .testTarget(name: "GadgetTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    private static func suite(_ name: String, tests count: Int, touching: Bool = true) -> String {
        let body = touching ? "_ = Widget()" : ""
        let tests = (0 ..< count).map { "    @Test func uses\($0)() { \(body) }" }.joined(separator: "\n")
        return "struct \(name) {\n\(tests)\n}\n"
    }

    private static func affected(libTests: [String: String], gadgetTests: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        for (target, files) in [("LibTests", libTests), ("GadgetTests", gadgetTests)] {
            for (name, source) in files {
                try TestSources.write("import Testing\n@testable import Lib\n\n" + source, to: "Tests/\(target)/\(name).swift", in: root)
            }
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// Every test of the target is affected: its heading is the one line, with the count and both commands, and no row or suite follows it.
    @Test
    func aFullyAffectedTargetIsOneLineWithItsCountAndBothCommands() async throws {
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: 14), "BetaTests": Self.suite("BetaTests", tests: 14)],
            gadgetTests: ["Orchard": Self.suite("Orchard", tests: 1, touching: false)]
        )

        #expect(output.contains("  LibTests: all 28 tests — swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests"))
        #expect(!output.contains("LibTests.AlphaTests/"))
        #expect(!output.contains("affected suites in this target"))
    }

    /// One target is fully affected and the other partly: the first is one line, and the second gets the commands that run exactly its affected suites, with no rows.
    @Test
    func aPartlyAffectedTargetGetsItsSuiteCommandsBesideAFullyAffectedOne() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: count)],
            gadgetTests: [
                "GizmoTests": Self.suite("GizmoTests", tests: count),
                "Orchard": Self.suite("Orchard", tests: count * 2, touching: false),
            ]
        )

        #expect(output.contains("  LibTests: all \(count) tests — swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests"))
        #expect(!output.contains("GadgetTests: all "))
        #expect(output.contains("    \(count) tests affected — the commands below run exactly the affected suites"))
        #expect(output.contains(#"    to run just these 1 suite: swift test --filter '^GadgetTests\.GizmoTests(/|$)'"#))
        #expect(output.contains("    to run just these 1 suite: xcodebuild test -only-testing:GadgetTests/GizmoTests"))
        #expect(!output.contains("GadgetTests.GizmoTests/"))
        #expect(!output.contains("truncated: "))
    }
}
