//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The corners of the nested-project rule: a store that is not SwiftPM's, a nested project built in-tree, and the cap on a written name.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNestedProjectRemainderTests {
    /// A test target added to a project a `buildServer.json` store built stays unbuilt, not outside.
    ///
    /// The package sits at `app/` and the root `.build` holds nothing, so the store is not SwiftPM's.
    @Test
    func aTestTargetAddedToAProjectABuildServerStoreBuiltStaysUnbuilt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(Self.manifest(name: "App", library: "Lib", testTargets: ["LibTests"]), to: "app/Package.swift", in: root)
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "app/Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "app/Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "app/Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        let app = root.appendingPathComponent("app")
        try await TestSources.swiftBuildSuspending(packageAt: app, includingTests: true)
        let store = try Self.builtStore(in: app)
        try TestSources.write("{\"indexStorePath\": \"app/.build/\(store)\"}\n", to: "buildServer.json", in: root)
        try TestSources.write(Self.manifest(name: "App", library: "Lib", testTargets: ["LibTests", "AppTests"]), to: "app/Package.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func doubles() {\n    #expect(Box().walk == 2)\n}\n", to: "app/Tests/AppTests/GizmoTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        #expect(affected.contains("semantic: partial (1 test file has no unit in the store"), "\(affected)")
        #expect(affected.contains("build its target"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("doubles()") && $0.contains("name match") }, "\(affected)")
        #expect(!affected.contains("outside any built target"), "\(affected)")
    }

    /// A test target added to a nested project an in-tree store built is not outside any built target.
    ///
    /// The root manifest does not declare it and the primary store never saw the package, yet the in-tree store's build would add it, so `where` counts it as not in the last build.
    @Test
    func aTestTargetAddedToAProjectAnInTreeStoreBuiltIsNotOutside() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(Self.manifest(name: "Lib", library: "Depot", testTargets: ["GadgetTests"]), to: "Package.swift", in: root)
        try TestSources.write("public struct Box {\n    public var idle = 0\n    public init() {}\n}\n", to: "Sources/Depot/Box.swift", in: root)
        try TestSources.write("@testable import Depot\nimport Testing\n\n@Test func opens() {\n    _ = Box()\n}\n", to: "Tests/GadgetTests/GizmoTests.swift", in: root)
        try TestSources.write(Self.manifest(name: "Sample", library: "Lib", testTargets: ["LibTests"]), to: "Sample/Package.swift", in: root)
        try TestSources.write("public struct Thing {\n    public var size = 1\n    public init() {}\n}\n", to: "Sample/Sources/Lib/Thing.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func sizes() {\n    #expect(Thing().size > 0)\n}\n", to: "Sample/Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let sample = root.appendingPathComponent("Sample")
        try await TestSources.swiftBuildSuspending(packageAt: sample, includingTests: true)
        // Where an `xcodebuild -derivedDataPath .build/sample-dd` build would leave the nested project's store.
        let inTree = sample.appendingPathComponent(".build/sample-dd/Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: inTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        let built = try Self.builtStore(in: sample)
        try FileManager.default.copyItem(at: sample.appendingPathComponent(".build/\(built)"), to: inTree)
        try TestSources.write(Self.manifest(name: "Sample", library: "Lib", testTargets: ["LibTests", "AppTests"]), to: "Sample/Package.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func grows() {\n    #expect(Thing().size == 1)\n}\n", to: "Sample/Tests/AppTests/GizmoTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let answer = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "Box.idle", freshness: freshness)
        }
        let verdict = try #require(answer.split(separator: "\n").first { $0.hasPrefix("no ") }.map(String.init), "\(answer)")

        #expect(verdict.contains("not counting 1 test file not in the last build"), "\(answer)")
        #expect(!verdict.contains("outside any built target"), "\(answer)")
    }

    /// Another project's files are no part of the count that makes a name too common, in either name walk.
    ///
    /// The test files the store has no unit for are matched by a name a crowd of nested-project files would otherwise make too common.
    @Test
    func anotherProjectsFilesDoNotMakeANameTooCommonForTheTestSideWalk() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(name: "Lib", library: "Lib", testTargets: ["LibTests"]), to: "Package.swift", in: root)
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk > 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            "name: Sample\ntargets:\n  SampleUITests:\n    type: bundle.ui-testing\n    platform: iOS\n    sources:\n      - path: SampleUITests\n",
            to: "Sample/project.yml",
            in: root
        )
        for index in 0 ... AffectedRenderer.nameEvidenceFileCap {
            try TestSources.write(
                "import Lib\nimport XCTest\n\nfinal class Crowd\(index)Tests: XCTestCase {\n    func testDoubling() {\n        XCTAssertEqual(Box().walk, 2)\n    }\n}\n",
                to: "Sample/SampleUITests/Crowd\(index)Tests.swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func walks() {\n    #expect(Box().walk == 2)\n}\n", to: "Tests/LibTests/GizmoTests.swift", in: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        #expect(affected.contains("\(AffectedRenderer.nameEvidenceFileCap + 1) test files outside any built target"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("walks()") && $0.contains("name match") }, "\(affected)")
        #expect(!affected.contains("written in more than"), "\(affected)")
    }

    /// The store directory a build of the package at `directory` left under its `.build`, relative to it, in whichever layout the toolchain writes.
    private static func builtStore(in directory: URL) throws -> String {
        guard let found = [".build/index/store", ".build/out"].first(where: { IndexStoreDiscovery.isStore(directory.appendingPathComponent($0)) }) else {
            throw GitError(message: "no index store under \(directory.path)/.build")
        }
        return String(found.dropFirst(".build/".count))
    }

    private static func manifest(name: String, library: String, testTargets: [String]) -> String {
        let tests = testTargets.map { ", .testTarget(name: \"\($0)\", dependencies: [\"\(library)\"])" }.joined()
        return """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [.target(name: "\(library)")\(tests)]
        )
        """
    }
}
