//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers index stores an `xcodebuild -derivedDataPath` build leaves inside the tree: their discovery, `where` reading one for a declaration the primary store lacks, and the line naming the project that builds a file no store covers.
@Suite(.temporaryDirectories)
struct InTreeIndexStoreTests {
    /// An empty store shape — a versioned `units` directory holding one file — which is all discovery reads.
    private static func makeStoreShape(at url: URL) throws {
        let units = url.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data().write(to: units.appendingPathComponent("u1"))
    }

    @Test
    func discoveryListsIgnoredInTreeStoresOnlyWithinTheDepthBound() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore"))
        try Self.makeStoreShape(at: root.appendingPathComponent("unignored-dd/Index.noindex/DataStore"))
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/a/b/c/deep-dd/Index.noindex/DataStore"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let found = discovery.discoverInTree(excluding: nil)

        #expect(found.map(\.provenance) == [.inTree(".build/runner-dd")])
        #expect(found.first?.path.path.hasSuffix(".build/runner-dd/Index.noindex/DataStore") == true)
    }

    @Test
    func aDeclarationThePrimaryStoreLacksIsAnsweredByTheInTreeStore() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        let primary = try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover()).path
        let inTree = root.appendingPathComponent(".build/fake-dd/Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: inTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: primary, to: inTree)
        // The primary keeps every unit but the one for Caller.swift, so only the in-tree copy covers that file.
        let units = try #require(IndexStoreDiscovery.unitsDirectory(in: primary))
        let callerUnits = try FileManager.default.contentsOfDirectory(at: units, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("Caller") }
        try #require(!callerUnits.isEmpty)
        for unit in callerUnits {
            try FileManager.default.removeItem(at: unit)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let helper = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "helper()", freshness: freshness)
        }
        let greet = try await engine.lookup(symbol: "greet()", freshness: freshness)

        #expect(helper.contains("mode: syntactic + semantic (index store via .build; in-tree store via .build/fake-dd)\n"))
        #expect(helper.contains("callers of Lib.helper() (1):"))
        #expect(helper.contains("callGreet"))
        #expect(!helper.contains("REFUSED"))
        #expect(greet.contains("mode: syntactic + semantic (index store via .build)\n"))
        #expect(greet.contains("overrides of Lib.Base.greet()"))
    }

    @Test
    func aFileNoStoreCoversNamesTheProjectThatBuildsItAndOnlyThatFile() async throws {
        let root = try TestSources.makeTempRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Orchard/Orchard.xcodeproj"), withIntermediateDirectories: true)
        try TestSources.write("func pick() {}\n", to: "Orchard/Sources/Picker.swift", in: root)
        try TestSources.write("func stray() {}\n", to: "Loose/Stray.swift", in: root)
        try TestSources.commitAll(in: root, message: "project-owned and loose files")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let owned = try await engine.lookup(symbol: "pick()", freshness: freshness)
        let loose = try await engine.lookup(symbol: "stray()", freshness: freshness)

        #expect(owned.contains("Orchard/Sources is built by Orchard/Orchard.xcodeproj; build it with -derivedDataPath inside the tree for semantic answers"))
        #expect(!loose.contains("is built by"))
    }

    @Test
    func theWalkVisitsNoMoreThanItsCapUnderAVastIgnoredTreeAndStillFindsAShallowStore() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\nnode_modules/\n", to: ".gitignore", in: root)
        try TestSources.write("{}\n", to: "node_modules/package.json", in: root)
        for package in 0 ..< 60 {
            for folder in 0 ..< 50 {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg\(package)/dir\(folder)"), withIntermediateDirectories: true)
            }
        }
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let found = discovery.discoverInTree(excluding: nil, reusing: nil)

        #expect(try #require(found.walk).visited <= InTreeStoreWalk.visitCap)
        #expect(found.stores.map(\.provenance) == [.inTree(".build/runner-dd")])
    }

    @Test
    func theWalkOrdersABuildNamedDirectoryBeforeAWiderSiblingThatSortsFirst() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\nnode_modules/\nxcbuild/\n", to: ".gitignore", in: root)
        // "node_modules" sorts before "xcbuild", so an unordered walk queues all of its children first.
        for package in 0 ..< 2100 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg\(package)"), withIntermediateDirectories: true)
        }
        try Self.makeStoreShape(at: root.appendingPathComponent("xcbuild/runner-dd/Index.noindex/DataStore"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let found = discovery.discoverInTree(excluding: nil, reusing: nil)

        #expect(found.stores.map(\.provenance) == [.inTree("xcbuild/runner-dd")])
        // `node_modules` never looks like build output, so it is visited once and never listed: the walk costs
        // what the small build-named subtree holds, not what the wide sibling holds.
        #expect(try #require(found.walk).visited < 10)
    }

    @Test
    func theWalkTruncatedByTheCapWithNoStoreFoundNamesItOnTheModeLineAndSuppressesTheProjectHint() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n*-dd/\n", to: ".gitignore", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Orchard/Orchard.xcodeproj"), withIntermediateDirectories: true)
        try TestSources.write("func pick() {}\n", to: "Orchard/Sources/Picker.swift", in: root)
        try TestSources.commitAll(in: root, message: "an owned file no store covers")
        // Every one of these matches the build-name heuristic (``.build`` and the ``-dd`` suffix), so all of them
        // are priority — and none holds a store, so the cap is genuinely exceeded with nothing found.
        for i in 0 ..< (InTreeStoreWalk.visitCap + 100) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("junk\(i)-dd"), withIntermediateDirectories: true)
        }
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        let found = discovery.discoverInTree(excluding: nil, reusing: nil)
        #expect(found.stores.isEmpty)
        #expect(try #require(found.walk).truncated)

        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let owned = try await engine.lookup(symbol: "pick()", freshness: freshness)

        #expect(owned.contains("in-tree walk cut short at \(InTreeStoreWalk.visitCap) directories"))
        #expect(!owned.contains("is built by"))
    }

    @Test
    func theWalkNeverEntersANestedCheckoutOrFollowsASymlink() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/nested/.git"), withIntermediateDirectories: true)
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/nested/Index.noindex/DataStore"))
        try Self.makeStoreShape(at: root.appendingPathComponent("elsewhere/Index.noindex/DataStore"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".build/linked-dd"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        #expect(discovery.discoverInTree(excluding: nil).map(\.provenance) == [.inTree(".build/runner-dd")])
    }

    @Test
    func aWalkIsReusedUntilADirectoryItVisitedChanges() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/scratch"), withIntermediateDirectories: true)
        try TestSources.write("func stray() {}\n", to: "Stray.swift", in: root)
        try TestSources.commitAll(in: root, message: "one file, one ignored directory")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        _ = try await engine.lookup(symbol: "stray()", freshness: freshness)
        _ = try await engine.lookup(symbol: "stray()", freshness: freshness)
        #expect(engine.inTree.walks == 1)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/runner-dd"), withIntermediateDirectories: true)
        _ = try await engine.lookup(symbol: "stray()", freshness: freshness)
        #expect(engine.inTree.walks == 2)
    }

    @Test
    func theFirstInTreeStoreInPathOrderOwnsADeclarationBothCover() async throws {
        let root = try Self.makeRepoWhosePrimaryLacksCaller(inTree: [".build/b-dd", ".build/a-dd"])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let helper = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "helper()", freshness: freshness)
        }

        #expect(helper.contains("mode: syntactic + semantic (index store via .build; in-tree store via .build/a-dd)\n"))
    }

    @Test
    func anInTreeStoreRebuiltBetweenQueriesLeavesOneOpenBehind() async throws {
        let root = try Self.makeRepoWhosePrimaryLacksCaller(inTree: [".build/fake-dd"])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        _ = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "helper()", freshness: freshness)
        }
        let inTree = root.appendingPathComponent(".build/fake-dd/Index.noindex/DataStore")
        let replacement = root.appendingPathComponent(".build/replacement")
        try FileManager.default.copyItem(at: inTree, to: replacement)
        try FileManager.default.removeItem(at: inTree)
        try FileManager.default.moveItem(at: replacement, to: inTree)

        let helper = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "helper()", freshness: freshness)
        }

        #expect(helper.contains("in-tree store via .build/fake-dd"))
        #expect(engine.inTree.openerCount == 1)
    }

    @Test
    func withNoPrimaryStoreOnlyWhereReadsTheInTreeStore() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        let primary = try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover()).path
        let inTree = root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: inTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: primary, to: inTree)
        try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover() == nil)
        // A change for `affected` to answer on.
        try TestSources.write("func extra() {}\n", to: "Sources/Lib/Extra.swift", in: root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let greet = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "greet()", freshness: freshness)
        }
        let affected = try await engine.affected(options: AffectedOptions(), freshness: freshness)
        let status = try engine.statusText(freshness: freshness)

        #expect(greet.contains("mode: syntactic + semantic (in-tree store via .build/runner-dd)\n"))
        #expect(greet.contains("overrides of Lib.Base.greet()"))
        #expect(!greet.contains("index store via"))
        #expect(affected.contains("mode: syntactic (sift help answers); "))
        #expect(!affected.contains("runner-dd"))
        #expect(status.contains("index store: none found"))
    }

    @Test
    func anEditedFileNoStoreCoversStillNamesItsProjectAndACoveredStaleFileDoesNot() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try TestSources.write("func wander() {}\n", to: "Runner/Sources/Walk.swift", in: root)
        let caller = root.appendingPathComponent("Sources/Lib/Caller.swift")
        try TestSources.write(String(contentsOf: caller, encoding: .utf8) + "\nfunc ripen() {}\n", to: "Sources/Lib/Caller.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let runner = try await engine.lookup(symbol: "wander()", freshness: freshness)
        let stale = try await engine.lookup(symbol: "ripen()", freshness: freshness)

        #expect(runner.contains("Runner/Sources is built by App.xcodeproj"))
        #expect(stale.contains("changed since the last build"))
        #expect(!stale.contains("is built by"))
    }

    @Test
    func deletingTheOnlyInTreeStoreWithNoPrimaryLetsItsOpenerGo() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        let primary = try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover()).path
        let runnerDD = root.appendingPathComponent(".build/runner-dd")
        let inTree = runnerDD.appendingPathComponent("Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: inTree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: primary, to: inTree)
        try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover() == nil)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        _ = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "greet()", freshness: freshness)
        }
        #expect(engine.inTree.openerCount == 1)

        try FileManager.default.removeItem(at: runnerDD)
        _ = try await engine.lookup(symbol: "greet()", freshness: freshness)

        #expect(engine.inTree.openerCount == 0)
    }

    @Test
    func aRealStaleRefusalIsNotHiddenBehindWarmingWhileAnInTreeStoreIsStillLoading() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        // Discovered fresh by this query, with no prior open to reuse — a budget of 0 below holds it warming.
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/fake-dd/Index.noindex/DataStore"))
        // No store, primary or in-tree, has ever compiled this file — genuinely stale, a fact a store opening
        // later can never change.
        try TestSources.write("func wisp() {}\n", to: "Sources/Lib/Extra.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        engine.openBudget = 0

        let stray = try await engine.lookup(symbol: "wisp()", freshness: freshness)

        #expect(!stray.contains("semantic: warming"), "\(stray)")
        #expect(stray.contains("changed since the last build"), "\(stray)")
    }

    @Test
    func aStaleDeclarationOwnedByAnInTreeStoreNamesThatStoreOnTheModeLineAndInTheRefusal() async throws {
        let root = try Self.makeRepoWhosePrimaryLacksCaller(inTree: [".build/fake-dd"])
        let caller = root.appendingPathComponent("Sources/Lib/Caller.swift")
        // The primary has no unit for this file at all, but the in-tree copy does — so it, not the primary, owns `callGreet()`, and editing the file after the copy was made makes only the in-tree store's answer stale.
        try TestSources.write(String(contentsOf: caller, encoding: .utf8) + "\n// touch\n", to: "Sources/Lib/Caller.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        // Bound to a name other than `callGreet` itself: a local variable's name is a real code declaration, and one that happens to match the fixture symbol would mask every string-literal sighting of it elsewhere in the tree, making the permit list's own entry look stale.
        let output = try await SemanticStoreWarmUp.settled {
            try await engine.lookup(symbol: "callGreet()", freshness: freshness)
        }

        #expect(output.contains("in-tree store via .build/fake-dd"))
        #expect(output.contains("changed since the last build; rebuild with -derivedDataPath .build/fake-dd"))
    }

    /// A row for a file no store covers, for the two `WhereStoreLines` tests below — the row's own fields play no part in either rule, only its `path` and whether `owner` names a project for it.
    private static func uncoveredRow() -> SymbolRow {
        SymbolRow(
            id: 1, fileID: 1, path: "Runner/Sources/Walk.swift", module: "Runner", parentID: nil, kind: .function, name: "wander()",
            line: 1, column: 1, endLine: 1, accessLevel: .internalLevel, isStatic: false, isStored: false,
            signature: "func wander()", docSummary: nil, ifConfigCondition: nil, viewOutline: nil
        )
    }

    /// A primary already at DerivedData is already the best build sift found — a miss under it is the declaration, not the build, so the project hint stays held back rather than suggesting a second build.
    @Test
    func aPrimaryAtDerivedDataSuppressesTheProjectHint() {
        var lines = ["mode: syntactic + semantic (index store via DerivedData)"]

        WhereStoreLines.appendProjectHintsIfAllowed(
            to: &lines,
            for: [Self.uncoveredRow()],
            owner: { _ in "Runner/Sources is built by App.xcodeproj" },
            inTreeWarming: false,
            primaryProvenance: .derivedData
        )

        #expect(lines == ["mode: syntactic + semantic (index store via DerivedData)"])
    }

    /// A loading in-tree store may yet turn out to cover the file, so the hint that assumes it never will is held back until the store settles.
    @Test
    func anInTreeStoreStillLoadingSuppressesTheProjectHint() {
        var lines = ["mode: syntactic + semantic (index store via .build)"]

        WhereStoreLines.appendProjectHintsIfAllowed(
            to: &lines,
            for: [Self.uncoveredRow()],
            owner: { _ in "Runner/Sources is built by App.xcodeproj" },
            inTreeWarming: true,
            primaryProvenance: .swiftPMBuild
        )

        #expect(lines == ["mode: syntactic + semantic (index store via .build)"])
    }

    /// The no-store path folds the generic "build one: …" advice out of the mode line once a project hint is going to print beside it, so the answer carries exactly one piece of build advice rather than two.
    @Test
    func theNoStorePathLeavesExactlyOneBuildAdviceLine() {
        var lines = [
            "mode: syntactic (sift help answers); no index store for this tree yet — "
                + "build one: \(SiftEngine.buildCommandNote). \(SiftEngine.nestedStoreNote). syntax-only otherwise.",
        ]

        WhereStoreLines.appendNoStoreProjectHints(
            to: &lines,
            for: [Self.uncoveredRow()],
            owner: { _ in "Runner/Sources is built by App.xcodeproj" }
        )

        // The generic advice is folded out of the mode line, and the one hint that replaces it names the project.
        #expect(lines.count == 3, "\(lines)")
        #expect(!lines[0].contains(SiftEngine.buildCommandNote))
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "Runner/Sources is built by App.xcodeproj")
    }

    /// A built package whose primary store has lost every unit for `Caller.swift`, with a full copy of the store at each of `inTree`, an ignored build directory.
    private static func makeRepoWhosePrimaryLacksCaller(inTree: [String], sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        let primary = try #require(IndexStoreDiscovery(repoRoot: root, config: SiftConfig()).discover(), sourceLocation: sourceLocation).path
        for directory in inTree {
            let store = root.appendingPathComponent(directory).appendingPathComponent("Index.noindex/DataStore")
            try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: primary, to: store)
        }
        let units = try #require(IndexStoreDiscovery.unitsDirectory(in: primary), sourceLocation: sourceLocation)
        for unit in try FileManager.default.contentsOfDirectory(at: units, includingPropertiesForKeys: nil) where unit.lastPathComponent.contains("Caller") {
            try FileManager.default.removeItem(at: unit)
        }
        return root
    }
}
