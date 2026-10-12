//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The per-query judge measures each cited file against its own build, not the store's newest unit.
@Suite(.temporaryDirectories)
struct PerFileFreshnessTests {
    /// A file edited after its unit and before another module's newer unit reads changed, which the store-wide anchor read as unchanged, and reads current once both modules are rebuilt.
    @Test
    func aFileAPartialBuildSkippedReadsChangedUntilBothAreRebuilt() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha", "Beta"])
        try TestSources.write("public struct Beta { let one = 1 }\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.write("public struct Alpha { let one = 1 }\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Alpha"])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let partial = try #require(engine.whereSemanticInput().context)
        let betaRow = try engine.store.fileRow(path: "Sources/Beta/Beta.swift")
        let beta = try #require(betaRow)
        try #require(beta.mtime < SemanticContext.buildAnchor(newestUnit: partial.store.newestUnitDate), "the store-wide anchor reads the skipped file as unchanged")

        let skipped = Self.judge(partial, engine: engine, root: root)
        let kind = skipped.kind(of: Self.absolute("Sources/Beta/Beta.swift", in: root))

        #expect(kind == .changed)
        #expect(skipped.state(of: Self.absolute("Sources/Beta/Beta.swift", in: root)) == .modifiedSinceBuild)
        #expect(skipped.modifiedFiles == ["Sources/Beta/Beta.swift"])
        #expect(skipped.kind(of: Self.absolute("Sources/Alpha/Alpha.swift", in: root)) == .current)

        try await TestSources.swiftBuildSuspending(packageAt: root)
        let rebuilt = try SiftEngine(directory: root)
        try await rebuilt.awaitSemanticStore()
        let full = try Self.judge(#require(rebuilt.whereSemanticInput().context), engine: rebuilt, root: root)

        #expect(full.kind(of: Self.absolute("Sources/Beta/Beta.swift", in: root)) == .current)
        #expect(full.kind(of: Self.absolute("Sources/Alpha/Alpha.swift", in: root)) == .current)
        #expect(full.modifiedFiles.isEmpty)
    }

    /// A path's newest unit is asked of the store once per open: a second query reuses the answer, and the store a newer build reopens asks again.
    @Test
    func aPathIsLookedUpOncePerOpenedStore() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let first = try #require(engine.whereSemanticInput().context)
        let spelling = try #require(SemanticStore.spellings(ofFile: "Sources/Alpha/Alpha.swift", under: root).first(where: first.store.hasUnit(forFile:)))
        let probed = first.store.unitLookups

        _ = Self.judge(first, engine: engine, root: root).kind(of: spelling)
        let second = try #require(engine.whereSemanticInput().context)
        _ = Self.judge(second, engine: engine, root: root).kind(of: spelling)

        #expect(second.store === first.store)
        #expect(first.store.unitLookups == probed)

        try TestSources.write("public struct Alpha { let one = 1 }\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root)
        try await engine.awaitSemanticStore()
        let reopened = try #require(engine.whereSemanticInput().context)
        let opened = reopened.store.unitLookups
        _ = Self.judge(reopened, engine: engine, root: root).kind(of: spelling)
        let afterOne = reopened.store.unitLookups
        _ = Self.judge(reopened, engine: engine, root: root).kind(of: spelling)

        #expect(reopened.store !== first.store)
        #expect(afterOne == opened + 1)
        #expect(reopened.store.unitLookups == afterOne)
    }

    /// A present path the index holds no row for is current, and a path `stat` cannot read is deleted.
    @Test
    func aPathWithNoRowIsCurrentAndOneStatCannotReadIsDeleted() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"])
        let outsider = try TemporaryDirectory.make("outsider").appendingPathComponent("Outsider.swift")
        try Data("let a = 1\n".utf8).write(to: outsider)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let judge = try Self.judge(#require(engine.whereSemanticInput().context), engine: engine, root: root)

        #expect(judge.kind(of: outsider.path) == .current)
        #expect(judge.kind(of: Self.absolute("Sources/Alpha/Missing.swift", in: root)) == .deleted)
        #expect(judge.deletedFiles == ["Sources/Alpha/Missing.swift"])
        #expect(judge.modifiedFiles.isEmpty)
        #expect(judge.newFiles.isEmpty)
    }

    /// A file two stores cite is judged against each store's own unit, and counted once under the worse kind, in whichever order the stores cite it.
    @Test
    func aFileCitedByTwoStoresIsInTheSetForTheWorseKindOnly() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"], extraFiles: ["Sources/Alpha/Beta.swift": "struct Beta {}\n", "Sources/Alpha/Gone.swift": "struct Gone {}\n"])
        let first = try SiftEngine(directory: root)
        try await first.awaitSemanticStore()
        let built = try #require(first.whereSemanticInput().context)
        let copy = try TemporaryDirectory.make("copied-store").appendingPathComponent("store")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: built.store.cache.storePath), to: copy)
        try TestSources.write("struct Beta { let one = 1 }\n", to: "Sources/Alpha/Beta.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root)
        try TestSources.write("struct Gone { let one = 1 }\n", to: "Sources/Alpha/Gone.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Alpha/Gone.swift"))
        let live = try #require(engine.whereSemanticInput().context)
        let older = try SemanticStore(
            discovered: DiscoveredStore(path: copy, provenance: .swiftPMBuild),
            repoRoot: root,
            newestUnitDate: IndexStoreDiscovery.newestUnitDate(in: copy) ?? .distantPast,
            cache: #require(SemanticCache(store: copy, in: TemporaryDirectory.make("copied-cache")))
        )
        var both = live
        both.inTreeStores = [older]
        let beta = try #require(SemanticStore.spellings(ofFile: "Sources/Alpha/Beta.swift", under: root).first(where: live.store.hasUnit(forFile:)))
        let gone = Self.absolute("Sources/Alpha/Gone.swift", in: root)

        let liveFirst = Self.judge(both, engine: engine, root: root)
        let liveKind = liveFirst.kind(of: beta, citedBy: live.store)
        let olderKind = liveFirst.kind(of: beta, citedBy: older)
        _ = liveFirst.kind(of: gone, citedBy: live.store)
        _ = liveFirst.kind(of: gone, citedBy: older)
        let olderFirst = Self.judge(both, engine: engine, root: root)
        _ = olderFirst.kind(of: beta, citedBy: older)
        _ = olderFirst.kind(of: beta, citedBy: live.store)

        #expect(liveKind == .current)
        #expect(olderKind == .changed)
        #expect(liveFirst.modifiedFiles == ["Sources/Alpha/Beta.swift"])
        #expect(liveFirst.deletedFiles == ["Sources/Alpha/Gone.swift"])
        #expect(olderFirst.modifiedFiles == ["Sources/Alpha/Beta.swift"])
    }

    /// A unit-less file in a nested package no store builds, or in a module the root manifest declares no target for, is not built, though it changed after every unit.
    @Test
    func aUnitLessFileNoBuildCompilesIsNotBuiltWhateverItsDates() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha"])
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Nested\", targets: [.target(name: \"Nested\")])\n",
            to: "Tools/Nested/Package.swift",
            in: root
        )
        try TestSources.write("struct Nested {}\n", to: "Tools/Nested/Sources/Nested/Nested.swift", in: root)
        try TestSources.write("struct Stray {}\n", to: "Sources/Stray/Stray.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let context = try #require(engine.whereSemanticInput().context)
        for path in ["Tools/Nested/Sources/Nested/Nested.swift", "Sources/Stray/Stray.swift"] {
            let found = try engine.store.fileRow(path: path)
            let row = try #require(found)
            try #require(row.mtime > SemanticContext.buildAnchor(newestUnit: context.store.newestUnitDate), "\(path) changed after every unit")
        }
        let judge = Self.judge(context, engine: engine, root: root)

        #expect(judge.kind(of: Self.absolute("Tools/Nested/Sources/Nested/Nested.swift", in: root)) == .notBuilt)
        #expect(judge.kind(of: Self.absolute("Sources/Stray/Stray.swift", in: root)) == .notBuilt)
        #expect(judge.newFiles.isEmpty)
        #expect(judge.modifiedFiles.isEmpty)
    }

    /// A declared module no build compiled is dated against the store's newest unit: a file changed after it is new, one changed before it not built.
    @Test
    func aDeclaredModuleNeverBuiltIsDatedAgainstTheStoresNewestUnit() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha", "Gamma"], building: "Alpha")
        try TestSources.write("struct Later {}\n", to: "Sources/Gamma/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let context = try #require(engine.whereSemanticInput().context)
        let judge = Self.judge(context, engine: engine, root: root)

        #expect(judge.kind(of: Self.absolute("Sources/Gamma/Later.swift", in: root)) == .new)
        #expect(judge.kind(of: Self.absolute("Sources/Gamma/Gamma.swift", in: root)) == .notBuilt)
        #expect(judge.newFiles == ["Sources/Gamma/Later.swift"])
        #expect(judge.modifiedFiles.isEmpty)
    }

    /// Judging a file the store holds a unit for never asks the filesystem how it spells the path, which walks every component; only a file no spelling as given finds a unit for does, once.
    @Test
    func onlyAFileWithNoUnitUnderTheGivenSpellingsAsksTheFilesystem() async throws {
        let root = try await Self.builtPackage(targets: ["Alpha", "Gamma"], building: "Alpha")
        try TestSources.write("struct Later {}\n", to: "Sources/Gamma/Later.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let judge = try Self.judge(#require(engine.whereSemanticInput().context), engine: engine, root: root)
        let held = try #require(try engine.store.fileRow(path: "Sources/Alpha/Alpha.swift"))
        let unitLess = try #require(try engine.store.fileRow(path: "Sources/Gamma/Later.swift"))

        #expect(judge.unrecordedKind(of: held) == .current)
        #expect(judge.kind(ofFile: "Sources/Alpha/Alpha.swift") == .current)
        #expect(judge.spellingWalks == 0)
        #expect(judge.unrecordedKind(of: unitLess) == .new)
        #expect(judge.spellingWalks == 1)
    }

    /// The `/private` spelling is tried only for a path under a directory macOS links into `/private`, since a build cannot have recorded any other path under it.
    @Test
    func thePrivateSpellingIsTriedOnlyUnderADirectoryLinkedIntoIt() {
        let linked = URL(fileURLWithPath: "/var/Absent/Package")
        let unlinked = URL(fileURLWithPath: "/Volumes/Absent/Package")

        #expect(SemanticStore.spellings(ofFile: "Sources/A.swift", under: linked) == ["/var/Absent/Package/Sources/A.swift", "/private/var/Absent/Package/Sources/A.swift"])
        #expect(SemanticStore.spellings(ofFile: "Sources/A.swift", under: unlinked) == ["/Volumes/Absent/Package/Sources/A.swift"])
    }
}

private extension PerFileFreshnessTests {
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

    static func judge(_ context: SemanticContext, engine: SiftEngine, root: URL) -> OccurrenceFreshness {
        OccurrenceFreshness(store: engine.store, context: context, projectDirectories: ModuleResolver(repoRoot: root, config: SiftConfig()).projectDirectories)
    }

    static func absolute(_ path: String, in root: URL) -> String {
        root.standardizedFileURL.path + "/" + path
    }
}
