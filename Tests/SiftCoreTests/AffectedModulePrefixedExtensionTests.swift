//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` resolving an extension written with its own module's name in front of the type it extends, for both test libraries.
@Suite(.serialized, .temporaryDirectories)
struct AffectedModulePrefixedExtensionTests {
    /// The answer for a repository whose `Bolt` gains a member after the fixture commit, with one source written under `Tests/LibTests/`.
    private static func affected(testSource: String) async throws -> String {
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
        try TestSources.write("public struct Bolt {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(testSource, to: "Tests/LibTests/Probe.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Bolt {\n    public init() {}\n    public func turn() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// A Swift Testing suite extended under its own module's name is reported, with the module once in the selector.
    @Test
    func aModulePrefixedExtensionReachesTheSuite() async throws {
        let output = try await Self.affected(testSource: """
        import Testing
        @testable import Lib

        struct Dup {
            @Test func spins() {}
        }

        extension LibTests.Dup {
            struct Holder {
                let bolt = Bolt()
            }
        }
        """)

        #expect(output.contains("-only-testing:LibTests/Dup"))
        #expect(!output.contains("LibTests/LibTests.Dup"))
    }

    /// An XCTest case extended under its own module's name is reported, with the module once in the selector.
    @Test
    func aModulePrefixedExtensionReachesTheXCTestCase() async throws {
        let output = try await Self.affected(testSource: """
        import XCTest
        @testable import Lib

        final class GadgetTests: XCTestCase {
            func testOne() {}
        }

        extension LibTests.GadgetTests {
            func helper() {
                _ = Bolt()
            }
        }
        """)

        #expect(output.contains("-only-testing:LibTests/GadgetTests"))
        #expect(!output.contains("LibTests/LibTests."))
    }

    /// A prefix naming some other module is not stripped, so it matches nothing.
    @Test
    func aForeignModulePrefixStaysUnmatched() async throws {
        let output = try await Self.affected(testSource: """
        import Testing
        @testable import Lib

        struct Dup {
            @Test func spins() {}
        }

        extension Lib.Dup {
            struct Holder {
                let bolt = Bolt()
            }
        }
        """)

        #expect(!output.contains("-only-testing:LibTests/Dup"))
    }

    /// A prefix that names a top-level type sharing the module's name is that type, not the module, so it stays in the selector.
    @Test
    func aPrefixNamingASameNamedTypeStays() async throws {
        let output = try await Self.affected(testSource: """
        import Testing
        @testable import Lib

        enum LibTests {
            struct S8 {
                @Test func z() {}
            }
        }

        extension LibTests.S8 {
            @Test func y() { _ = Bolt() }
        }
        """)

        #expect(output.contains("LibTests/LibTests"))
        #expect(output.contains("S8/y()"))
        #expect(!output.contains("-only-testing:LibTests/S8"))
    }
}
