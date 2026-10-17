//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how `affected` names a target past the per-test cap: a target whose every test is affected is one line with the filter that runs it, a partial one carries the complete filter for its suites on one line, and a refused changed file is not expanded into its declarations.
///
/// No build: the name-match fallback reaches these tests, which is all the output's shape needs.
@Suite(.temporaryDirectories)
struct AffectedWholeTargetTests {
    private static func manifest() -> String {
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

    private static func suite(_ name: String, tests count: Int, touching: Bool = true) -> String {
        let body = touching ? "_ = Widget()" : ""
        let tests = (0 ..< count).map { "    @Test func uses\($0)() { \(body) }" }.joined(separator: "\n")
        return "struct \(name) {\n\(tests)\n}\n"
    }

    private static func affected(testFiles: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        for (name, source) in testFiles {
            try TestSources.write("import Testing\n@testable import Lib\n\n" + source, to: "Tests/LibTests/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// Every test in the target is affected: one line says so and gives the filter, and no suite is listed.
    @Test
    func aWholeTargetIsOneLineWithItsFilterAndNoSuiteList() async throws {
        let output = try await Self.affected(testFiles: [
            "AlphaTests": Self.suite("AlphaTests", tests: 14),
            "BetaTests": Self.suite("BetaTests", tests: 14),
        ])

        #expect(output.contains("  LibTests: all 28 tests — swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests"))
        #expect(!output.contains("affected suites in this target"))
        #expect(!output.contains("each with the filter that selects it"))
        #expect(!output.contains("truncated: "))
    }

    /// A target only partly affected is not called whole, and its suite filters are on one line, however long, with no per-suite rows.
    @Test
    func aPartialTargetPastTheCapCarriesTheCompleteFilterOnOneLine() async throws {
        let count = AffectedRenderer.testListCap + 20
        let suites = (0 ..< count).map { Self.suite("Suite\($0)Tests", tests: 1) }.joined(separator: "\n")
        let output = try await Self.affected(testFiles: [
            "GizmoTests": suites,
            "Orchard": Self.suite("Orchard", tests: count * 2, touching: false),
        ])

        #expect(!output.contains("LibTests: all "))
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("    to run just these \(count) suites: swift test ") })
        for index in 0 ..< count {
            #expect(line.contains(#"--filter '^LibTests\.Suite\#(index)Tests(/|$)'"#))
        }
        #expect(!line.contains("Orchard"))
        #expect(!output.contains("truncated: "))
        #expect(!output.contains("affected suites in this target"))
    }

    /// A changed file the store refuses is counted, not expanded into the declarations the name match used.
    @Test
    func aRefusedChangedFileIsNotExpandedIntoItsDeclarations() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\n" + Self.suite("AlphaTests", tests: 2), to: "Tests/LibTests/AlphaTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        // Written after the build, so the store refuses every declaration in the file.
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)

        #expect(output.contains("semantic REFUSED — Sources/Lib/Core.swift was changed since the last build"))
        #expect(!output.contains("Lib.Widget (struct)"))
        #expect(!output.contains("declarations: "))
        #expect(output.contains("after-edit walk — syntactic, lower bound: the 1 file changed since the build was seeded from the 1 name the diff touched there (shine)"))
    }
}
