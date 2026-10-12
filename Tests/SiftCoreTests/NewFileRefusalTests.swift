//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The declaring file is judged against its own build: a file a partial build skipped is refused, a new file is refused as new, and a file no build adds is not refused as stale.
@Suite(.temporaryDirectories)
struct NewFileRefusalTests {
    /// A declaration in a file edited before a build of another target alone is refused, with SwiftPM's command, which builds every target.
    @Test
    func aSkippedEditedFileInSwiftPMsStoreIsRefusedWithTheSwiftPMCommand() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Beta", freshness: freshness)

        #expect(output.contains("semantic: stale since last build (1 file changed: Sources/Beta/Beta.swift)"), "\(output)")
        #expect(output.contains("Beta.Beta — struct"), "\(output)")
        #expect(output.contains("semantic REFUSED — changed since the last build; rebuild with `sift run -- swift build`, then retry"), "\(output)")
    }

    /// The same skipped file, owned by a store other than SwiftPM's, is refused naming the module its last build did not compile.
    @Test
    func aSkippedEditedFileInAnXcodeStoreNamesTheModuleTheLastBuildDidNotCompile() async throws {
        let root = try await Self.partiallyRebuiltPackage()
        let primary = try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover()).path
        let inTree = root.appendingPathComponent(".build/fake-dd/Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: inTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: primary, to: inTree)
        let units = try #require(IndexStoreDiscovery.unitsDirectory(in: primary))
        for unit in try FileManager.default.contentsOfDirectory(at: units, includingPropertiesForKeys: nil) where unit.lastPathComponent.contains("Beta") {
            try FileManager.default.removeItem(at: unit)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "Beta", freshness: freshness)
        }

        #expect(output.contains("in-tree store via .build/fake-dd"), "\(output)")
        #expect(output.contains("changed since the last build; the last build did not compile Beta — build a scheme or target that does, then retry"), "\(output)")
        #expect(!output.contains("-derivedDataPath"), "\(output)")
    }

    /// A declaration in a file added to a built module since the build is refused as new, counted stale, and the judge puts the file in its new set.
    @Test
    func aDeclarationInANewFileIsRefusedAsNew() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"])
        try TestSources.write("public struct Later {}\n", to: "Sources/Alpha/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Later", freshness: freshness)
        let judge = try Self.judge(#require(engine.whereSemanticInput().context), engine: engine, root: root)
        let kind = judge.kind(of: root.standardizedFileURL.path + "/Sources/Alpha/Later.swift")

        #expect(output.contains("semantic: stale since last build (1 new file: Sources/Alpha/Later.swift)"), "\(output)")
        #expect(output.contains("semantic REFUSED — new since the last build; rebuild with `sift run -- swift build`, then retry"), "\(output)")
        #expect(!output.contains("was changed since the last build"), "\(output)")
        #expect(kind == .new)
        #expect(judge.newFiles == ["Sources/Alpha/Later.swift"])
        #expect(judge.modifiedFiles.isEmpty)
    }

    /// A unit-less file in a declared module that a build since its change left out reads as not found in the store, not stale.
    @Test
    func aUnitLessFileABuildSinceItsChangeLeftOutReadsNotFound() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha", "Gamma"], extraFiles: ["Sources/Gamma/Later.swift": "public struct Later {}\n"], building: "Alpha")
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Later", freshness: freshness)

        #expect(output.contains("semantic: fresh, 1 declaration not found in the store"), "\(output)")
        #expect(!output.contains("since the last build"), "\(output)")
    }

    /// A unit-less file edited after every unit, in a nested package no store builds, is not refused as changed or new.
    @Test
    func aUnitLessEditedFileInANestedProjectIsNotRefusedAsStale() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"])
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Nested\", targets: [.target(name: \"Nested\")])\n",
            to: "Tools/Nested/Package.swift",
            in: root
        )
        try TestSources.write("struct Nested {}\n", to: "Tools/Nested/Sources/Nested/Nested.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Nested", freshness: freshness)

        #expect(output.contains("semantic: fresh, 1 declaration not found in the store"), "\(output)")
        #expect(!output.contains("since the last build"), "\(output)")
    }

    /// A type moved out of a deleted file into a new one is not resolved by the definition the store recorded in the deleted file: it is refused as new.
    @Test
    func aDefinitionRecordedOnlyInADeletedFileNeverResolvesTheTreesDeclaration() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"], extraFiles: ["Sources/Alpha/Gamma.swift": "struct Later {}\n"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Alpha/Gamma.swift"))
        try TestSources.write("struct Later {}\n", to: "Sources/Alpha/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Later", freshness: freshness)

        #expect(output.contains("Sources/Alpha/Later.swift"), "\(output)")
        #expect(!output.contains("Sources/Alpha/Gamma.swift"), "\(output)")
        #expect(output.contains("semantic REFUSED — new since the last build"), "\(output)")
    }
}

private extension NewFileRefusalTests {
    /// A committed package declaring `targets`, each with one file declaring a struct of its name, built whole or, given `building`, that target alone.
    static func builtPackage(targets: [String], extraFiles: [String: String] = [:], building: String? = nil) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        let declared = targets.map { ".target(name: \"\($0)\")" }.joined(separator: ", ")
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [\(declared)])\n",
            to: "Package.swift",
            in: root
        )
        for target in targets {
            try TestSources.write("public struct \(target) {}\n", to: "Sources/\(target)/\(target).swift", in: root)
        }
        for (path, text) in extraFiles {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: building.map { ["--target", $0] } ?? [])
        return root
    }

    /// Two targets built whole, then the second's file edited below its declaration and the first rebuilt alone, so the edit predates the store's newest unit.
    static func partiallyRebuiltPackage() async throws -> URL {
        let root = try await builtPackage(targets: ["Alpha", "Beta"])
        try TestSources.write("public struct Beta {}\n// edited\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.write("public struct Alpha {}\n// rebuilt\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Alpha"])
        return root
    }

    static func judge(_ context: SemanticContext, engine: SiftEngine, root: URL) -> OccurrenceFreshness {
        OccurrenceFreshness(store: engine.store, context: context, projectDirectories: ModuleResolver(repoRoot: root, config: SiftConfig()).projectDirectories)
    }
}
