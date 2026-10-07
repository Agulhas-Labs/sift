//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` resolving the class an extension extends by its whole written name when the test library is XCTest.
@Suite(.serialized, .temporaryDirectories)
struct AffectedXCTestExactExtensionTests {
    /// The answer for a repository whose `Bolt` gains a member after the fixture commit, with one XCTest source written under `Tests/LibTests/`.
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

    /// An extension of a top-level type does not take the XCTest case of a same-named class nested elsewhere.
    @Test
    func anExtensionDoesNotMatchASameNamedNestedXCTestCase() async throws {
        let output = try await Self.affected(testSource: """
        import XCTest
        @testable import Lib

        enum Space {
            final class Dup: XCTestCase {
                func testOne() {}
            }
        }

        struct Dup {}

        extension Dup {
            func helper() {
                _ = Bolt()
            }
        }
        """)

        #expect(!output.contains("Dup"))
        #expect(!output.contains("-only-testing"))
    }
}
