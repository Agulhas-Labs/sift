//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers Docs/Design.md §6: delete-then-insert stability, cascade cleanup, and the schema-mismatch nuclear reset.
@Suite(.temporaryDirectories)
struct StorageLifecycleTests {
    private static var widgetSource: String {
        """
        /// A widget.
        public struct Widget: Equatable, Codable {
            public var name: String
            func reload() {}
        }
        """
    }

    @Test
    func reindexingAFileTwiceKeepsCountsStable() throws {
        let store = try TestSources.makeStore()
        let file = try TestSources.parsed(Self.widgetSource, path: "Sources/App/Widget.swift")
        try store.replaceFiles([file]) { _ in ("App", false) }
        let first = try store.counts()

        try store.replaceFiles([file]) { _ in ("App", false) }
        let second = try store.counts()

        #expect(first.files == 1)
        #expect(second.files == first.files)
        #expect(second.symbols == first.symbols)
        let hits = try store.symbols(named: "Widget")
        #expect(hits.count == 1)
    }

    @Test
    func deletingAFileCascadesSymbolsInheritanceAndFTS() throws {
        let store = try TestSources.makeStore()
        let file = try TestSources.parsed(Self.widgetSource, path: "Sources/App/Widget.swift")
        try store.replaceFiles([file]) { _ in ("App", false) }

        try store.deleteFiles(paths: ["Sources/App/Widget.swift"])
        let counts = try store.counts()

        #expect(counts.files == 0)
        #expect(counts.symbols == 0)
        #expect(try store.conformers(of: "Equatable").isEmpty)
        #expect(try store.searchCandidates(prefix: "Widg", limit: 5).isEmpty)
    }

    @Test
    func searchCandidatesSurviveFTSKeywordPrefixes() throws {
        let store = try TestSources.makeStore()
        let file = try TestSources.parsed("struct ANDGate {}\nstruct NOTGate {}", path: "Sources/App/Gates.swift")
        try store.replaceFiles([file]) { _ in ("App", false) }

        let andHits = try store.searchCandidates(prefix: "AND", limit: 5)
        let notHits = try store.searchCandidates(prefix: "NOT", limit: 5)

        #expect(andHits.contains { $0.name == "ANDGate" })
        #expect(notHits.contains { $0.name == "NOTGate" })
    }

    /// Acceptance (Docs/Design.md §7): index size is stable — demonstrably non-monotonic — across 50 alternating branch switches.
    ///
    /// The failure this guards is Docs/Design.md §6.1 rot: a broken delete-then-insert duplicates rows on every reparse, and the symptom — slowly degrading results — is easy to miss for weeks. Fifty cycles of duplication would explode both the row counts (asserted exactly, per branch) and the file size (asserted bounded over the steady window). Compaction does not run inside the loop: it follows the initial full build, the incremental path's deletes are never followed by one, and the every-20th-incremental reconcile finds a converged tree with nothing to remove — so the bound holds on SQLite reusing the pages those deletes free.
    @Test
    func indexSizeIsStableAcrossFiftyAlternatingBranchSwitches() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Shared { let a: Int }", to: "Sources/App/Shared.swift", in: root)
        try TestSources.write("struct MainOnly { func run() {} }", to: "Sources/App/MainOnly.swift", in: root)
        try TestSources.commitAll(in: root, message: "main files")
        try TestSources.runGit(["checkout", "-b", "alt"], in: root)
        try TestSources.runGit(["rm", "Sources/App/MainOnly.swift"], in: root)
        try TestSources.write("enum AltOnly { case a, b }", to: "Sources/App/AltOnly.swift", in: root)
        try TestSources.write("protocol AltProto { func p() }", to: "Sources/App/AltProto.swift", in: root)
        try TestSources.commitAll(in: root, message: "alt files")
        try TestSources.runGit(["checkout", "main"], in: root)

        let engine = try SiftEngine(directory: root)
        var expectedCounts: [String: IndexCounts] = [:]
        var sizes: [Int64] = []
        for cycle in 0 ..< 50 {
            let branch = cycle.isMultiple(of: 2) ? "alt" : "main"
            try TestSources.runGit(["checkout", branch], in: root)
            try await engine.ensureFresh()
            let counts = try engine.store.counts()
            if let expected = expectedCounts[branch] {
                #expect(counts.files == expected.files, "files drifted on \(branch) at cycle \(cycle)")
                #expect(counts.symbols == expected.symbols, "symbols drifted on \(branch) at cycle \(cycle)")
            } else {
                expectedCounts[branch] = counts
            }
            sizes.append(engine.store.databaseSizeBytes)
        }

        let steady = sizes.dropFirst(4)
        let minimum = steady.min() ?? 0
        let maximum = steady.max() ?? 0

        #expect(minimum > 0)
        #expect(maximum <= minimum * 3 / 2, "index size grew monotonically: \(sizes)")
    }

    @Test
    func schemaVersionMismatchDropsAndRebuilds() throws {
        let directory = try TemporaryDirectory.make("schema")
            .appendingPathComponent("schema")
        let databasePath = directory.appendingPathComponent("index.db").path
        let store = try IndexStore(databasePath: databasePath)
        let file = try TestSources.parsed(Self.widgetSource, path: "Sources/App/Widget.swift")
        try store.replaceFiles([file]) { _ in ("App", false) }

        let raw = try SQLiteDatabase(path: databasePath)
        try raw.execute("PRAGMA user_version = 99")
        let reopened = try IndexStore(databasePath: databasePath)

        #expect(try reopened.counts().files == 0)
    }

    /// An index written before the doc-summary cap re-derives every summary on the first query an upgraded binary answers, changed file or not.
    ///
    /// The cap runs at parse time and its output is stored, and an unchanged file is never reparsed — so the only thing that reaches an index built under the old rule is the schema version. The stored summary is written back to an uncapped one and the version to the one before the cap, which is exactly what an upgraded user's index holds.
    @Test
    func anIndexFromBeforeTheSummaryCapReDerivesItsSummaries() async throws {
        let root = try TestSources.makeTempRepo()
        let long = "Serves the widget with every field it carries, and then the rest of the sentence runs on well past eighty bytes"
        try TestSources.write("/// \(long)\nstruct Widget {\n    let name: String\n}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "widget")
        let first = try SiftEngine(directory: root)
        try await first.ensureFresh()
        let databasePath = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path
        let raw = try SQLiteDatabase(path: databasePath)
        try raw.execute("UPDATE symbols SET doc_summary = '\(long)' WHERE name = 'Widget'")
        try raw.execute("PRAGMA user_version = 4")

        let upgraded = try SiftEngine(directory: root)
        try await upgraded.ensureFresh()
        let summary = try #require(upgraded.store.symbols(named: "Widget").first?.docSummary)

        #expect(summary != long)
        #expect(summary.utf8.count <= 80 + "…".utf8.count)
    }

    /// An index written before subscripts and enum cases with associated values were named as the index store names them re-derives both names on the first query an upgraded binary answers, changed file or not.
    ///
    /// A name is derived at parse time and stored, and an unchanged file is never reparsed — so the only thing that reaches an index built under the old rule is the schema version. The stored names are written back to the old spellings and the version to the one before the rule, which is exactly what an upgraded user's index holds; kept, each is a name no store row carries, and every `where` on it is refused.
    @Test
    func anIndexFromBeforeTheStoresNamingRuleReDerivesSubscriptAndCaseNames() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Shelf {\n    subscript(slot: Int) -> Int { slot }\n}\n\nenum Mode {\n    case value(Int)\n}\n",
            to: "Sources/App/Shelf.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "shelf")
        let first = try SiftEngine(directory: root)
        try await first.ensureFresh()
        let databasePath = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path
        let raw = try SQLiteDatabase(path: databasePath)
        try raw.execute("UPDATE symbols SET name = 'subscript(slot:)' WHERE name = 'subscript(_:)'")
        try raw.execute("UPDATE symbols SET name = 'value' WHERE name = 'value(_:)'")
        try raw.execute("PRAGMA user_version = 5")
        #expect(try first.store.symbols(named: "subscript(slot:)").map(\.name) == ["subscript(slot:)"])
        #expect(try first.store.symbols(named: "value").map(\.name) == ["value"])

        let upgraded = try SiftEngine(directory: root)
        try await upgraded.ensureFresh()

        #expect(try upgraded.store.symbols(named: "subscript").map(\.name) == ["subscript(_:)"])
        #expect(try upgraded.store.symbols(named: "value").map(\.name) == ["value(_:)"])
    }

    /// A store knows when its own file has been deleted or replaced — the identity a long-lived cache has to check before answering from an open handle.
    @Test
    func aStoreReportsItsBackingFileGoneOnceDeletedOrReplaced() throws {
        let directory = try TemporaryDirectory.make("identity")
            .appendingPathComponent("identity")
        let databasePath = directory.appendingPathComponent("index.db").path
        let store = try IndexStore(databasePath: databasePath)

        #expect(store.isBackingFileIntact)

        // What a `git clean -xfd` does: the whole cache directory, WAL sidecars included.
        try FileManager.default.removeItem(at: directory)
        #expect(!store.isBackingFileIntact)

        // A *replacement* at the same path is as dead to this handle as a deletion — checking mere path existence would call this one healthy.
        _ = try IndexStore(databasePath: databasePath)
        #expect(!store.isBackingFileIntact)
    }
}
