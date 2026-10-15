//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how `status` decides that a unit on disk still names a deleted file: by the whole path the unit records, never a suffix of it, and only then saying the store's record keeps the file.
@Suite(.temporaryDirectories) struct StatusUnitPathMatchTests {
    /// A deleted `Sources/Lib/Caller.swift` beside a live `Sources/MyLib/Caller.swift` and a live `Sources/Other/Lib/Caller.swift`: a build without cleaning keeps the deleted file's unit and `status` counts it, and once a clean build drops that unit the live files' units, whose paths end the same way, do not keep it counted.
    @Test
    func aLiveFileWhosePathEndsLikeTheDeletedOneDoesNotKeepItCountedAfterACleanBuild() async throws {
        let root = try Self.threeCallersRepo()
        try TestSources.swiftBuild(packageAt: root)
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        _ = try await SiftEngine(directory: root).ensureFresh()
        try TestSources.swiftBuild(packageAt: root)

        let afterBuild = try await Self.status(in: root)

        #expect(afterBuild.contains("semantic: stale since last build (1 file deleted: Sources/Lib/Caller.swift)"))
        #expect(StatusRenameThenBuildTests.linesAfterTheStoreLine(of: afterBuild) == [SiftEngine.statusAxisNote, SiftEngine.statusDeletedNote])

        try FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        try TestSources.swiftBuild(packageAt: root)

        let afterClean = try await Self.status(in: root)

        #expect(afterClean.contains("semantic: fresh"))
        #expect(StatusRenameThenBuildTests.linesAfterTheStoreLine(of: afterClean) == [SiftEngine.statusAxisNote])
    }

    /// A file added after the build and deleted again is counted on the ledger's date, but no unit names it, so `status` says nothing about the store's record keeping it.
    @Test
    func aDeletedFileNoUnitNamesIsCountedWithoutTheRecordLine() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: root).ensureFresh()
        try TestSources.write("public func added() {}\n", to: "Sources/Lib/New.swift", in: root)
        _ = try await Self.status(in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/New.swift"))

        let status = try await Self.status(in: root)

        #expect(status.contains("semantic: stale since last build (1 file deleted: Sources/Lib/New.swift)"))
        #expect(StatusRenameThenBuildTests.linesAfterTheStoreLine(of: status) == [SiftEngine.statusAxisNote])
    }

    /// Each prefix kind a unit records a path under is joined to the whole path: the working directory, the SDK root, and an absolute directory as Xcode writes one outside its working directory.
    @Test
    func aUnitsPathsAreJoinedFromTheirPrefixKind() {
        let unit = IndexUnitFixture.unit(workingDirectory: "/work", sdkRoot: "/SDK", paths: [
            IndexUnitFixture.Path(kind: 1, directory: "Sources/Lib", file: "Caller.swift"),
            IndexUnitFixture.Path(kind: 2, directory: "usr/lib/swift", file: "Swift.swiftmodule"),
            IndexUnitFixture.Path(kind: 0, directory: "/derived/Sources/App", file: "App.swift"),
            IndexUnitFixture.Path(kind: 1, directory: "", file: "Top.swift"),
        ])

        #expect(IndexUnitPaths.of(unit) == [
            "/work/Sources/Lib/Caller.swift",
            "/SDK/usr/lib/swift/Swift.swiftmodule",
            "/derived/Sources/App/App.swift",
            "/work/Top.swift",
        ])
        #expect(IndexUnitPaths.of(Data("/work/Sources/LibCaller.swift".utf8)).isEmpty)
        #expect(IndexUnitPaths.of(unit.prefix(unit.count / 2)).isEmpty)
    }

    /// A unit's recorded path counts only when it is the deleted file's own path: not one under a directory whose name ends like the file's parent, nor one under a same-named subdirectory of another module.
    @Test
    func onlyTheWholeRecordedPathNamesAFile() throws {
        let store = try TemporaryDirectory.make("unit-paths")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try IndexUnitFixture.write(workingDirectory: "/work", path: "Sources/MyLib", file: "Caller.swift", named: "Caller.swift.o-1ABC", in: units)
        try IndexUnitFixture.write(workingDirectory: "/work", path: "Sources/Other/Lib", file: "Caller.swift", named: "Caller.swift.o-2DEF", in: units)

        let mentions = StoreUnitMentions(store: store, root: URL(fileURLWithPath: "/work"))

        #expect(!mentions.names(file: "Sources/Lib/Caller.swift"))
        #expect(mentions.names(file: "Sources/MyLib/Caller.swift"))
        #expect(mentions.names(file: "Sources/Other/Lib/Caller.swift"))
    }

    /// A recorded path outside the root names the deleted file where it ends with `/` and the file's repository-relative path and is gone from disk, as a checkout moved since its build leaves it; not where it ends so mid-component, nor where it is still on disk, nor inside the root, where a nested package's missing `Packages/X/Sources/Lib/Caller.swift` only ends the same way.
    @Test
    func aPathOutsideTheRootNamesTheFileOnlyWhereAMovedCheckoutLeftIt() throws {
        let elsewhere = try TemporaryDirectory.make("elsewhere")
        try TestSources.write("public func dependencyCall() {}\n", to: "Sources/Lib/Caller.swift", in: elsewhere)

        #expect(try Self.mentions(recording: "/moved/repo", "Sources/Lib").names(file: "Sources/Lib/Caller.swift"))
        #expect(try !Self.mentions(recording: "/moved/repo", "XSources/Lib").names(file: "Sources/Lib/Caller.swift"))
        #expect(try !Self.mentions(recording: elsewhere.path, "Sources/Lib").names(file: "Sources/Lib/Caller.swift"))
        #expect(try !Self.mentions(recording: "/work", "Packages/X/Sources/Lib").names(file: "Sources/Lib/Caller.swift"))
    }

    /// The mentions, for the root `/work`, of a store whose one unit records `Caller.swift` under `directory` relative to `workingDirectory`.
    private static func mentions(recording workingDirectory: String, _ directory: String) throws -> StoreUnitMentions {
        let store = try TemporaryDirectory.make("unit-paths")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try IndexUnitFixture.write(workingDirectory: workingDirectory, path: directory, file: "Caller.swift", named: "Caller.swift.o-1ABC", in: units)
        return StoreUnitMentions(store: store, root: URL(fileURLWithPath: "/work"))
    }

    /// The package the boundary case needs: three modules, each with a `Caller.swift`, one of them a folder deeper under a directory named like the first module.
    private static func threeCallersRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Callers",
                targets: [.target(name: "Lib"), .target(name: "MyLib"), .target(name: "Other")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Base {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("public func libCall() {}\n", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.write("public func myLibCall() {}\n", to: "Sources/MyLib/Caller.swift", in: root)
        try TestSources.write("public func otherCall() {}\n", to: "Sources/Other/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "three callers")
        return root
    }

    private static func status(in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        return try await engine.statusText(freshness: engine.ensureFresh())
    }
}
