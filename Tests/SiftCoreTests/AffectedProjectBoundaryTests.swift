//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Which unit-less test files `affected` counts as another project's is decided by the project they sit in, not by whether their module has a unit: a test target added to the package since the last test build is the package's own, and a nested project's files stay out of the fallback's runner lines too.
@Suite(.serialized, .temporaryDirectories)
struct AffectedProjectBoundaryTests {
    /// A test target the root manifest declares, added after `--build-tests`, has no unit in any file of its module and is still unbuilt: counted toward `partial`, given the build advice, and matched by name; a stray file in a module the manifest declares no target for is named outside instead.
    @Test
    func aTestTargetAddedToThePackageSinceTheBuildStaysUnbuilt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(testTargets: ["LibTests"]), to: "Package.swift", in: root)
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        // Declared and written after the build: no file of the new target has a unit, and a rebuild adds them all.
        try TestSources.write(Self.manifest(testTargets: ["LibTests", "AppTests"]), to: "Package.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func doubles() {\n    #expect(Box().walk == 2)\n}\n", to: "Tests/AppTests/GizmoTests.swift", in: root)
        // In the root package's own tree but in no target its manifest declares: no build of the package compiles it.
        try TestSources.write("import Lib\nimport Testing\n\n@Test func stray() {\n    #expect(Box().walk == 2)\n}\n", to: "Tests/Fixtures/GadgetTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        #expect(affected.contains("semantic: partial (1 test file has no unit in the store"), "\(affected)")
        #expect(affected.contains("build it with `sift run -- swift build --build-tests`"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("doubles()") && $0.contains("name match") }, "\(affected)")
        #expect(affected.contains("\n1 test file outside any built target: no build of the store's project compiles it"), "\(affected)")
        #expect(!affected.contains("stray()"), "\(affected)")
    }

    /// An edit since the build refuses the store's answer and falls back to the name walk, which leaves the nested project's test file out of every runner line while still listing the package's own test.
    @Test
    func theFallbackWalkLeavesANestedProjectsTestFilesOut() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(testTargets: ["LibTests"]), to: "Package.swift", in: root)
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
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        // Edited after the build, in the working tree: the store's answer for it is refused, and the name walk stands in.
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(), freshness: engine.ensureFresh())
        let diff = try await DiffEngineTests.diff(root)

        #expect(affected.contains("semantic: stale"), "\(affected)")
        #expect(affected.contains("1 test file outside any built target: no build of the store's project compiles it, so no test in it was matched"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("reads()") && $0.contains("name match") }, "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("--filter") && $0.contains("reads") }, "\(affected)")
        #expect(!affected.contains("SampleUITests"), "\(affected)")
        // Diff's callers block still names the nested file's use of `walk`, which is a use in the tree; only its reaching tests leave it out.
        #expect(diff.contains("tests reaching the changed files (1 test in 1 target)"), "\(diff)")
        #expect(!diff.split(separator: "\n").contains { $0.contains("SampleUITests") && $0.contains("hop") }, "\(diff)")
    }

    /// A manifest that writes some targets literally and others by a computed name could declare any module, so a test target added to it since the build is not read as outside: it stays unbuilt, advised and matched by name.
    @Test
    func aManifestWithAComputedTargetNameDoesNotHideANewTestTarget() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(testTargets: ["LibTests"]), to: "Package.swift", in: root)
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let computed = Self.manifest(testTargets: ["LibTests"]).replacingOccurrences(of: "targets: [", with: "targets: [.testTarget(name: [\"AppTests\"][0], dependencies: [\"Lib\"]), ")
        try TestSources.write(computed, to: "Package.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func doubles() {\n    #expect(Box().walk == 2)\n}\n", to: "Tests/AppTests/GizmoTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        #expect(affected.contains("semantic: partial"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("doubles()") && $0.contains("name match") }, "\(affected)")
        #expect(!affected.contains("outside any built target"), "\(affected)")
    }

    private static func manifest(testTargets: [String]) -> String {
        let tests = testTargets.map { ".testTarget(name: \"\($0)\", dependencies: [\"Lib\"])" }.joined(separator: ", ")
        return """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib"), \(tests)]
        )
        """
    }
}
