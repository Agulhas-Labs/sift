//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` resolving the type an extension extends by its whole written name, and reading a suite's library from the suite's own file.
@Suite(.serialized, .temporaryDirectories)
struct AffectedExtensionResolutionTests {
    /// The answer for a repository whose `Bolt` gains a member after the fixture commit, with `tests` written under `Tests/LibTests/`.
    private static func affected(tests: [(path: String, source: String)]) async throws -> String {
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
        for test in tests {
            try TestSources.write(test.source, to: "Tests/LibTests/\(test.path)", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Bolt {\n    public init() {}\n    public func turn() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// An extension of a top-level type does not take the suite of a same-named type nested elsewhere.
    @Test
    func anExtensionDoesNotMatchASameNamedNestedSuite() async throws {
        let output = try await Self.affected(tests: [(path: "Dup.swift", source: """
        import Testing
        @testable import Lib

        enum Space {
            struct Dup {
                @Test func spins() {}
            }
        }

        struct Dup {}

        extension Dup {
            struct Holder {
                let bolt = Bolt()
            }
        }
        """)])

        #expect(!output.contains("LibTests.Dup"))
        #expect(!output.contains("-only-testing:LibTests/Dup"))
    }

    /// A qualified extension does not take the suite of a same-named type declared elsewhere.
    @Test
    func aQualifiedExtensionDoesNotMatchASameNamedSuite() async throws {
        let output = try await Self.affected(tests: [(path: "Inner.swift", source: """
        import Testing
        @testable import Lib

        struct Inner {
            @Test func spins() {}
        }

        enum Outer {
            struct Inner {}
        }

        extension Outer.Inner {
            struct Holder {
                let bolt = Bolt()
            }
        }
        """)])

        #expect(!output.contains("LibTests.Inner"))
        #expect(!output.contains("LibTests.Outer"))
    }

    /// A qualified extension of a nested suite still names that suite.
    @Test
    func aQualifiedExtensionOfANestedSuiteNamesIt() async throws {
        let output = try await Self.affected(tests: [(path: "Inner.swift", source: """
        import Testing
        @testable import Lib

        enum Outer {
            struct Inner {
                @Test func spins() {}
            }
        }

        extension Outer.Inner {
            struct Holder {
                let bolt = Bolt()
            }
        }
        """)])

        #expect(output.contains("LibTests.Outer/Inner — 1 hop"))
    }

    /// An extension file that imports no test library still rolls up to the suite declared in another file.
    @Test
    func anExtensionFileWithoutATestImportNamesTheSuite() async throws {
        let output = try await Self.affected(tests: [
            (path: "Lamp.swift", source: "import Testing\n@testable import Lib\n\nstruct LampTests {\n    @Test func lit() {}\n}\n"),
            (path: "Spring.swift", source: "@testable import Lib\n\nextension LampTests {\n    struct Fixture {\n        let bolt = Bolt()\n    }\n}\n"),
        ])

        #expect(output.contains("LibTests.LampTests — 1 hop"))
        #expect(!output.contains("LampTests.Fixture"))
    }
}
