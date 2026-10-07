//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A declaration refused because its file is newer than SwiftPM's `.build` names the exact rebuild, with `--build-tests` only where its file is a test file, which a plain `swift build` never rebuilds.
@Suite(.serialized, .temporaryDirectories)
struct WhereRebuildCommandTests {
    @Test
    func aStaleDeclarationNamesTheSwiftPMRebuildAndATestFileAddsBuildTests() async throws {
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
        let fixture = "@testable import Lib\nimport Testing\n\nstruct Holder {\n    var probe = Box().walk\n}\n"
        try TestSources.write(fixture + "\n@Test func reads() {\n    #expect(Holder().probe == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        // Both files edited after the build, the ordinary state of a tree mid-change.
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write(fixture + "\n@Test func reads() {\n    #expect(Holder().probe == 2)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let source = try await engine.lookup(symbol: "Box.walk", freshness: engine.ensureFresh())
        let test = try await engine.lookup(symbol: "Holder.probe", freshness: engine.ensureFresh())

        #expect(source.contains("semantic REFUSED — changed since the last build; rebuild with `sift run -- swift build`, then retry"), "\(source)")
        #expect(test.contains("semantic REFUSED — changed since the last build; rebuild with `sift run -- swift build --build-tests`, then retry"), "\(test)")
    }
}
