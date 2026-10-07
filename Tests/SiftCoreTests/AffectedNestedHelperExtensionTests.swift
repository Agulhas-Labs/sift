//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` naming the suite for a helper type nested in an extension of that suite, in the same file or another file of the test target, and not naming an extension of a type that is no suite.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNestedHelperExtensionTests {
    /// The answer for a repository whose `Widget` gains a member after the fixture commit, with `tests` written under `Tests/LibTests/`, over a build when `built` is set.
    private static func affected(built: Bool, tests: [(path: String, source: String)]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for test in tests {
            try TestSources.write(test.source, to: "Tests/LibTests/\(test.path)", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        if built {
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    private static var suiteSource: String {
        """
        import Testing
        @testable import Lib

        struct LampTests {
            @Test func lit() {
                _ = Fixture()
            }
        }
        """
    }

    private static var helperExtension: String {
        """
        extension LampTests {
            struct Fixture {
                let widget = Widget()
            }
        }
        """
    }

    /// A helper in an extension written below the suite in the same file names the suite, by name match.
    @Test
    func aHelperInASameFileExtensionNamesTheSuite() async throws {
        let source = Self.suiteSource + "\n\n" + Self.helperExtension
        let output = try await Self.affected(built: false, tests: [(path: "LampTests.swift", source: source)])

        #expect(output.contains("LibTests.LampTests — 1 hop, name match"))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// The same helper over a build names the suite as a resolved reference.
    @Test
    func aResolvedHelperInASameFileExtensionNamesTheSuite() async throws {
        let source = Self.suiteSource + "\n\n" + Self.helperExtension
        let output = try await Self.affected(built: true, tests: [(path: "LampTests.swift", source: source)])

        #expect(output.contains("LibTests.LampTests — 1 hop — "))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// A helper in an extension written in another file of the test target names the suite.
    @Test
    func aHelperInAnOtherFileExtensionNamesTheSuite() async throws {
        let output = try await Self.affected(built: false, tests: [
            (path: "LampTests.swift", source: Self.suiteSource),
            (path: "Helpers.swift", source: "import Testing\n@testable import Lib\n\n" + Self.helperExtension),
        ])

        #expect(output.contains("LibTests.LampTests — 1 hop, name match"))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// An extension of a type that has no tests is no suite, so nothing is reported for its helper.
    @Test
    func anExtensionOfANonSuiteTypeIsNotReported() async throws {
        let output = try await Self.affected(built: false, tests: [(path: "Gizmo.swift", source: """
        import Testing
        @testable import Lib

        struct Gizmo {}

        extension Gizmo {
            struct Fixture {
                let widget = Widget()
            }
        }
        """)])

        #expect(!output.contains("Gizmo"))
        #expect(!output.contains("LampTests.Fixture"))
    }
}
