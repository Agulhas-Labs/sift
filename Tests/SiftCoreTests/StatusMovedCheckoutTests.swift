//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a unit recording a deleted file somewhere other than under the root as given: a checkout moved since its build, whose old units record its old place, and a nested package inside the root holding the same repository-relative path.
@Suite(.temporaryDirectories) struct StatusMovedCheckoutTests {
    /// A checkout moved since its build, a file deleted there and the package built again without cleaning: the build writes new units for the new place and keeps the old ones, which record the deleted file under the old place, so `status` reads stale with the record line, as a query citing the file does.
    @Test
    func aCheckoutMovedSinceItsBuildCountsTheDeletedFileItsOldUnitsRecord() async throws {
        let built = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: built).ensureFresh()
        let root = try TemporaryDirectory.make("moved").resolvingSymlinksInPath().appendingPathComponent("repo")
        try FileManager.default.moveItem(at: built, to: root)
        ChildDeadline.widenGitReads(under: root, to: 120)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        _ = try await SiftEngine(directory: root).ensureFresh()
        try TestSources.swiftBuild(packageAt: root)

        let status = try await Self.status(in: root)

        #expect(status.contains("semantic: stale since last build (1 file deleted: Sources/Lib/Caller.swift)"))
        #expect(StatusRenameThenBuildTests.linesAfterTheStoreLine(of: status) == [SiftEngine.statusAxisNote, SiftEngine.statusDeletedNote])
    }

    /// A nested package holding `Sources/Lib/Caller.swift` too: its unit records that path inside the root, where it only ends like the deleted file's, so once a clean build drops the deleted file's own unit `status` reads fresh.
    @Test
    func aNestedPackagesFileEndingLikeTheDeletedOneDoesNotKeepItCountedAfterACleanBuild() async throws {
        let root = try Self.nestedPackageRepo()
        try TestSources.swiftBuild(packageAt: root)
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        try TestSources.swiftBuild(packageAt: root)

        let status = try await Self.status(in: root)

        #expect(status.contains("semantic: fresh"))
        #expect(StatusRenameThenBuildTests.linesAfterTheStoreLine(of: status) == [SiftEngine.statusAxisNote])
    }

    /// A package whose `Lib` depends on a nested package at `Packages/X` with a target at `Sources/Lib` of its own, each holding a `Caller.swift`.
    private static func nestedPackageRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Outer",
                dependencies: [.package(path: "Packages/X")],
                targets: [.target(name: "Lib", dependencies: [.product(name: "XLib", package: "X")])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "X",
                products: [.library(name: "XLib", targets: ["XLib"])],
                targets: [.target(name: "XLib", path: "Sources/Lib")]
            )
            """,
            to: "Packages/X/Package.swift",
            in: root
        )
        try TestSources.write("public struct Base {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("public func libCall() {}\n", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.write("public func nestedCall() {}\n", to: "Packages/X/Sources/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "nested package")
        return root
    }

    private static func status(in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        return try await engine.statusText(freshness: engine.ensureFresh())
    }
}
