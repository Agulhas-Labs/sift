//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A zero-use verdict never states an absence of uses from test files the store holds no unit for.
///
/// `no references to X recorded in the store` is the line a deletion is decided on; built without the test target, the store records no reference from a test, so a type used only by its tests read as one nothing uses.
@Suite(.serialized, .temporaryDirectories)
struct WhereUnbuiltTestsZeroUseTests {
    /// A type and a property used only from a test file, built without `--build-tests`: both zero-use verdicts say the test file is not in the store and how to add it.
    @Test
    func aTypeUsedOnlyByItsTestsIsNotAnsweredAsUnused() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let type = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh())
        let property = try await engine.lookup(symbol: "Box.walk", freshness: engine.ensureFresh())
        let hedge = "recorded in the store; 1 test file is not in it (build with `sift run -- swift build --build-tests`)"

        #expect(type.contains("no references to Lib.Box \(hedge) — check comments and strings with grep"), "\(type)")
        #expect(property.contains("no reads or writes of Lib.Box.walk \(hedge)"), "\(property)")
    }
}
