//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The unbuilt-test-targets note is owed only to a package that declares a test target.
@Suite(.temporaryDirectories)
struct BuildTimingNoTestTargetTests {
    private static func package(manifestTargets: String) throws -> URL {
        let made = try TemporaryDirectory.make("build-timing-manifest")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Widget\", targets: [\(manifestTargets)])\n", to: "Package.swift", in: root)
        return root
    }

    private static func render(packageHasTestTargets: Bool) throws -> String {
        let made = try TemporaryDirectory.make("build-timing-note-none")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        let timings = [BuildTiming(milliseconds: 6, path: root.path + "/A.swift", line: 1, column: 1, kind: .body)]
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 4)
        return BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 5, logURL: nil, top: 4, builtWithTests: false, packageHasTestTargets: packageHasTestTargets)
    }

    @Test
    func aPackageWithNoTestTargetIsNotToldToRebuildWithBuildTests() throws {
        let answer = try Self.render(packageHasTestTargets: false)

        #expect(!answer.contains("test targets are not built"))
        #expect(!answer.contains("--build-tests"))
    }

    @Test
    func aPackageWithATestTargetBuiltWithoutItIsToldSo() throws {
        let answer = try Self.render(packageHasTestTargets: true)

        #expect(answer.contains("test targets are not built"))
    }

    @Test
    func theManifestSaysWhetherATestTargetIsDeclared() throws {
        let with = try Self.package(manifestTargets: ".target(name: \"Widget\"), .testTarget(name: \"WidgetTests\", dependencies: [\"Widget\"])")
        let without = try Self.package(manifestTargets: ".target(name: \"Widget\")")

        #expect(SwiftPMManifest.declaresTestTargets(inPackageAt: with))
        #expect(!SwiftPMManifest.declaresTestTargets(inPackageAt: without))
    }
}
