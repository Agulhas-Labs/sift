//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `status` after files are renamed and the tree built again without cleaning: the build keeps each old name's unit, so a query goes on citing the old file, and `status` has to count what the store still records whichever order the rename, the build and this index noticing them came in.
///
/// Every query is asked again while the store is still loading (``SemanticStoreWarmUp``), because a `warming` answer is a statement about the machine's load rather than about the axis these tests compare.
@Suite(.temporaryDirectories) struct StatusRenameThenBuildTests {
    /// A `git mv` and a build in one command: the index first notices the renames after the build, and both `status` and a query citing an old name read the old files as deleted, with the line saying a build without cleaning keeps them.
    @Test
    func aRenameAndABuildInOneCommandReadAsDeletedOnStatusAndOnAQueryCitingThem() async throws {
        let root = try await Self.indexedRepo()
        try Self.renameBoth(in: root)
        try TestSources.swiftBuild(packageAt: root)

        let (helper, status) = try await Self.axes(in: root)

        #expect(helper.contains("semantic: stale since last build (1 cited file deleted: Sources/Lib/Caller.swift)"))
        #expect(status.contains("semantic: stale since last build (2 files deleted)"))
        #expect(Self.linesAfterTheStoreLine(of: status) == [SiftEngine.statusAxisNote, SiftEngine.statusDeletedNote])
    }

    /// The renames noticed before the build: the ledger dates them earlier than the build, yet the build kept their units and a query still cites the old file, so `status` must count them too rather than read `fresh`.
    @Test
    func aRenameNoticedBeforeTheBuildStillCountsTheOldNamesTheStoreRecords() async throws {
        let root = try await Self.indexedRepo()
        try Self.renameBoth(in: root)
        _ = try await SiftEngine(directory: root).ensureFresh()
        try TestSources.swiftBuild(packageAt: root)

        let (helper, status) = try await Self.axes(in: root)

        #expect(helper.contains("semantic: stale since last build (1 cited file deleted: Sources/Lib/Caller.swift)"))
        #expect(status.contains("semantic: stale since last build (2 files deleted)"))
        #expect(status.contains(SiftEngine.statusDeletedNote))
    }

    /// A build that compiles nothing keeps both readings where they were, and a clean build — the store deleted and built again — drops the old names from both.
    @Test
    func aNoOpBuildKeepsTheOldNamesCountedAndACleanBuildDropsThem() async throws {
        let root = try await Self.indexedRepo()
        try Self.renameBoth(in: root)
        try TestSources.swiftBuild(packageAt: root)
        _ = try await SiftEngine(directory: root).ensureFresh()
        try TestSources.swiftBuild(packageAt: root)

        let (helperAfterNoOp, statusAfterNoOp) = try await Self.axes(in: root)

        #expect(helperAfterNoOp.contains("semantic: stale since last build (1 cited file deleted: Sources/Lib/Caller.swift)"))
        #expect(statusAfterNoOp.contains("semantic: stale since last build (2 files deleted)"))

        try FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        try TestSources.swiftBuild(packageAt: root)

        let (helperAfterClean, statusAfterClean) = try await Self.axes(in: root)

        #expect(helperAfterClean.contains("semantic: fresh"))
        #expect(statusAfterClean.contains("semantic: fresh"))
        #expect(!statusAfterClean.contains(SiftEngine.statusDeletedNote))
    }

    /// Only the units named for a deleted file's stem are read, each once however many deleted paths share the stem, so the check stays bounded by what the ledger names rather than by the size of the store.
    @Test
    func onlyUnitsNamedForTheFilesStemAreRead() throws {
        let store = try TemporaryDirectory.make("unit-mentions")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try IndexUnitFixture.write(workingDirectory: "/work", path: "Sources/Lib", file: "Caller.swift", named: "Caller.o-1ABC", in: units)
        try IndexUnitFixture.write(workingDirectory: "/work", path: "Sources/Lib", file: "Other.swift", named: "Other.o-2DEF", in: units)
        try IndexUnitFixture.write(workingDirectory: "/work", path: "Sources/Lib", file: "Widget.swift", named: "Widget.o-3GHI", in: units)

        let mentions = StoreUnitMentions(store: store, root: URL(fileURLWithPath: "/work"))

        #expect(mentions.names(file: "Sources/Lib/Caller.swift"))
        #expect(!mentions.names(file: "Sources/App/Caller.swift"))
        #expect(!mentions.names(file: "Sources/Lib/Gone.swift"))
        #expect(mentions.unitsRead == 1)
    }

    /// The built fixture, indexed once, so a later rename is a drop this index records.
    private static func indexedRepo() async throws -> URL {
        let root = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    private static func renameBoth(in root: URL) throws {
        try TestSources.runGit(["mv", "Sources/Lib/Caller.swift", "Sources/Lib/Calling.swift"], in: root)
        try TestSources.runGit(["mv", "Sources/Lib/Base.swift", "Sources/Lib/Bases.swift"], in: root)
    }

    /// What a query citing the old `Caller.swift` and `status` each report, from an engine opened after the last build.
    private static func axes(in root: URL) async throws -> (helper: String, status: String) {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let helper = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "helper()", freshness: freshness) }
        return try (helper, engine.statusText(freshness: freshness))
    }

    /// Every line after the `index store:` line, which is where `status` explains its semantic field; this fixture has no parse errors or guessed modules to follow it.
    static func linesAfterTheStoreLine(of status: String) -> [String] {
        let lines = status.split(separator: "\n").map(String.init)
        guard let store = lines.firstIndex(where: { $0.hasPrefix("index store: ") }) else { return [] }
        return Array(lines[(store + 1)...])
    }
}
