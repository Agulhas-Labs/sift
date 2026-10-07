//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where` names the test files with no unit the way `affected` does: a file the last build skipped apart from one no build of the store's project would add.
///
/// A tally that lumped both under one phrase sent a reader to rebuild for files no rebuild adds, or told them nothing could help when a rebuild would.
@Suite(.serialized, .temporaryDirectories)
struct WhereTestCoverageClassificationTests {
    /// A package built with its tests, optionally with a test file added to its built target since and a nested XcodeGen project's test file; the `used by` line for `Box` is returned.
    private func verdict(of symbol: String = "Box", addedSinceBuild: Bool, nestedProject: Bool) async throws -> String {
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
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public var idle = 0\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        if nestedProject {
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
        }
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        if addedSinceBuild {
            try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func walks() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GizmoTests.swift", in: root)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let answer = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        return answer.split(separator: "\n").first { $0.hasPrefix(symbol == "Box" ? "used by " : "no ") }.map(String.init) ?? answer
    }

    @Test
    func aFileTheLastBuildSkippedAndANestedProjectsFileAreNamedApart() async throws {
        let verdict = try await verdict(addedSinceBuild: true, nestedProject: true)

        #expect(verdict.contains("production · 1 test, a lower bound (1 test file not in the last build — rebuild the tests to count them; 1 outside any built target)"), "\(verdict)")
    }

    @Test
    func onlyOutsideFilesNameOnlyTheOutsideCount() async throws {
        let verdict = try await verdict(addedSinceBuild: false, nestedProject: true)

        #expect(verdict.contains("production · 1 test, a lower bound (1 test file outside any built target)"), "\(verdict)")
        #expect(!verdict.contains("not in the last build"), "\(verdict)")
    }

    @Test
    func onlyASkippedFileNamesOnlyTheRebuild() async throws {
        let verdict = try await verdict(addedSinceBuild: true, nestedProject: false)

        #expect(verdict.contains("production · 1 test, a lower bound (1 test file not in the last build — rebuild the tests to count them)"), "\(verdict)")
        #expect(!verdict.contains("outside any built target"), "\(verdict)")
    }

    @Test
    func everyTestFileBuiltLeavesNoParenthetical() async throws {
        let verdict = try await verdict(addedSinceBuild: false, nestedProject: false)

        #expect(verdict.contains("production · 1 test"), "\(verdict)")
        #expect(!verdict.contains("lower bound"), "\(verdict)")
        #expect(!verdict.contains("not in the last build"), "\(verdict)")
        #expect(!verdict.contains("outside any built target"), "\(verdict)")
    }

    @Test
    func aZeroUseVerdictNamesBothKindsApart() async throws {
        let verdict = try await verdict(of: "Box.idle", addedSinceBuild: true, nestedProject: true)

        #expect(verdict.contains("recorded in the store; not counting 1 test file not in the last build — rebuild the tests to count them, and 1 outside any built target"), "\(verdict)")
    }

    @Test
    func aZeroUseVerdictNamesOnlyASkippedFileAsSuch() async throws {
        let verdict = try await verdict(of: "Box.idle", addedSinceBuild: true, nestedProject: false)

        #expect(verdict.contains("recorded in the store; not counting 1 test file not in the last build — rebuild the tests to count them"), "\(verdict)")
        #expect(!verdict.contains("outside any built target"), "\(verdict)")
    }
}
