//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The scan by written name takes its files by the judge: a file a partial build skipped is read, each file it lists is in the judge's set for its kind, and a file no store holds is listed as new.
@Suite(.temporaryDirectories)
struct PartialBuildScanTests {
    /// A caller edited before a build of another target alone is read against its own build, so the call it gained is listed by name.
    @Test
    func aFileEditedBeforeAPartialBuildThatSkippedItIsScanned() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha.ping", freshness: freshness)

        #expect(output.contains("Sources/Beta/Beta.swift (1):  (file changed since last build)") && output.contains("\n    written since the build, by name: :5"), "\(output)")
    }

    /// The file a changed caller's by-name lines come from is in the judge's changed set, and a new file's in its new set and no other.
    @Test
    func theByNameFilesAreInTheJudgesSetForTheirKind() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        try TestSources.write("func later() {\n    Alpha().ping()\n}\n", to: "Sources/Alpha/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        let context = try #require(engine.whereSemanticInput().context)
        let judge = OccurrenceFreshness(store: engine.store, context: context, projectDirectories: ModuleResolver(repoRoot: root, config: SiftConfig()).projectDirectories)

        let mentions = try WhereChangedFileMentions(names: ["ping"], unbuilt: [], refused: [], in: engine.store, context: context, judge: judge, listsEveryLine: false)

        #expect(judge.modifiedFiles == ["Sources/Beta/Beta.swift"])
        #expect(judge.newFiles == ["Sources/Alpha/Later.swift"])
        #expect(judge.deletedFiles.isEmpty)
        #expect(mentions.newFiles == ["Sources/Alpha/Later.swift"])
    }

    /// The lines of a file no store holds a unit for are headed as new since the last build.
    @Test
    func theNotInTheStoreLineIsHeadedNew() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        try TestSources.write("func later() {\n    Alpha().ping()\n}\n", to: "Sources/Alpha/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha.ping", freshness: freshness)

        #expect(output.contains("new since last build, not in the store, mention the name: Sources/Alpha/Later.swift:2"), "\(output)")
        #expect(!output.contains("changed since last build, not in the store"), "\(output)")
    }
}

private extension PartialBuildScanTests {
    /// A package whose `Beta` target calls `Alpha.ping` once, built whole; then the call written a second time in `Beta` and `Alpha` alone rebuilt, so the edit predates the store's newest unit but not its own file's.
    static func partiallyRebuiltPackage() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\", dependencies: [\"Alpha\"])])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Alpha {\n    public init() {}\n    public func ping() {}\n}\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try TestSources.write("import Alpha\n\npublic func beta() {\n    Alpha().ping()\n}\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        try TestSources.write("import Alpha\n\npublic func beta() {\n    Alpha().ping()\n    Alpha().ping()\n}\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.write("public struct Alpha {\n    public init() {}\n    public func ping() {}\n}\n// rebuilt\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Alpha"])
        return root
    }
}
