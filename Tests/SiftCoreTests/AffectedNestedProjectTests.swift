//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A package built with its tests beside another project nested in the same tree: a test build of the package can never compile the nested project's test files, so they are neither counted as unbuilt, nor advised a build, nor walked into runner lines naming a target the package does not have.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNestedProjectTests {
    /// A library change a nested XcodeGen target's test names, after `--build-tests`: the nested file is named outside any built target and never listed, while a test file added to the built test target since still counts, still gets the build advice and is still matched.
    @Test
    func aNestedProjectsTestFilesAreNamedOutsideTheBuildAndNeverWalked() async throws {
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
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            "name: Sample\ntargets:\n  SampleUITests:\n    type: bundle.ui-testing\n    platform: iOS\n    sources:\n      - path: SampleUITests\n",
            to: "Sample/project.yml",
            in: root
        )
        try TestSources.write(
            "import Lib\nimport XCTest\n\nfinal class SampleUITests: XCTestCase {\n    func testDoubling() {\n        XCTAssertEqual(Box().walk, 2)\n    }\n}\n",
            to: "Sample/SampleUITests/SampleUITests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        // Written after the build, into the test target it compiled: a rebuild adds this one, so it stays unbuilt.
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func walks() {\n    #expect(Box().walk == 2)\n}\n", to: "Tests/LibTests/GizmoTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())
        let diff = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(affected.contains("semantic: partial (1 test file has no unit in the store"), "\(affected)")
        #expect(affected.contains("1 test file outside any built target: no build of the store's project compiles it"), "\(affected)")
        #expect(affected.contains("test files without a unit: 1 test file has no unit in the store"), "\(affected)")
        #expect(affected.contains("build it with `sift run -- swift build --build-tests`"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("walks()") && $0.contains("name match") }, "\(affected)")
        #expect(!affected.contains("SampleUITests"), "\(affected)")
        #expect(!diff.contains("SampleUITests"), "\(diff)")
    }
}
