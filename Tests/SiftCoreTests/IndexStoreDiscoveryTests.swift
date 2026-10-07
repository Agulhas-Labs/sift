//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the four-step store discovery order with fabricated filesystems (Docs/Design.md §2).
@Suite(.temporaryDirectories)
struct IndexStoreDiscoveryTests {
    private static func makeRepo() throws -> URL {
        try TemporaryDirectory.make("discovery")
    }

    private static func makeStore(at url: URL, version: String = "v5", builtAt date: Date? = nil) throws {
        let unit = url.appendingPathComponent("\(version)/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: unit)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
        }
    }

    /// A DerivedData entry named `name` whose `info.plist` records `workspace`, with a store whose one unit was written at `date`; the workspace itself is created on disk, as a real build leaves it.
    @discardableResult
    private static func makeEntry(named name: String, in derivedData: URL, workspace: URL, builtAt date: Date? = nil) throws -> URL {
        let entry = derivedData.appendingPathComponent(name)
        let store = entry.appendingPathComponent("Index.noindex/DataStore")
        try makeStore(at: store, builtAt: date)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WorkspacePath": workspace.path]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: entry.appendingPathComponent("info.plist"))
        return store
    }

    /// Whether two URLs name one directory — discovery lists DerivedData through `/private/var`, where the fixture was built through `/var`.
    private static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    /// A linked worktree's root at `path` under `root`: a directory holding the `.git` file every linked worktree carries.
    private static func makeWorktree(at path: String, under root: URL) throws -> URL {
        let worktree = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere/.git/worktrees/\(worktree.lastPathComponent)".utf8)
            .write(to: worktree.appendingPathComponent(".git"))
        return worktree
    }

    @Test
    func explicitConfigPathWinsFirst() throws {
        let root = try Self.makeRepo()
        try Self.makeStore(at: root.appendingPathComponent("custom/store"))
        var config = SiftConfig()
        config.indexStorePath = "custom/store"
        let discovery = IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .config)
    }

    @Test
    func swiftPMBuildStoreIsFound() throws {
        let root = try Self.makeRepo()
        try Self.makeStore(at: root.appendingPathComponent(".build/index/store"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .swiftPMBuild)
        #expect(discovered.path.path.hasSuffix(".build/index/store"))
    }

    /// Swift Build — SwiftPM's default build system as of Swift 6.4 — writes the store into `.build/out` itself, and `.build/debug` is then a symlink into `out/Products/Debug` that holds no store, so a checkout it built is found at `.build/out` or not at all.
    @Test
    func aSwiftBuildStoreUnderBuildOutIsFound() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent(".build/out")
        try Self.makeStore(at: out)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("Products/Debug"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".build/debug").path,
            withDestinationPath: "out/Products/Debug"
        )
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .swiftPMBuild)
        #expect(Self.same(discovered.path, out), "\(discovered.path)")
    }

    /// Both SwiftPM layouts in one `.build` resolve to whichever holds the newest unit, in both directions: the other describes the tree at an earlier build.
    ///
    /// A native store left at `.build/index/store` from before a toolchain upgrade — the flag this suite's own fixture builder passes, and Swift Build ignores — must lose to the `.build/out` the upgrade's first build writes; and a `--build-system native` build after that, re-pointing `.build/debug` at its own per-configuration directory, must win over the `.build/out` it leaves behind.
    @Test
    func whenBothSwiftPMLayoutsHoldAStoreTheNewestUnitWins() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        let out = root.appendingPathComponent(".build/out")
        try Self.makeStore(at: root.appendingPathComponent(".build/index/store"), builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Self.makeStore(at: out, builtAt: Date(timeIntervalSince1970: 1_800_000_000))

        let upgraded = try #require(discovery.discover())

        #expect(Self.same(upgraded.path, out), "the store left from before the upgrade must not win: \(upgraded.path)")

        let nativeStore = root.appendingPathComponent(".build/arm64-apple-macosx/debug/index/store")
        try Self.makeStore(at: nativeStore, builtAt: Date(timeIntervalSince1970: 1_900_000_000))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(".build/debug").path,
            withDestinationPath: "arm64-apple-macosx/debug"
        )

        let rebuiltNative = try #require(discovery.discover())

        #expect(Self.same(rebuiltNative.path, nativeStore), "the newer native build must win over .build/out: \(rebuiltNative.path)")
    }

    /// The rule holds between the native configurations too: a release store indexed after the last debug build wins, where a fixed order once put debug first whichever was built last.
    @Test
    func aReleaseStoreIndexedAfterTheLastDebugBuildWins() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent(".build/release/index/store")
        try Self.makeStore(at: root.appendingPathComponent(".build/debug/index/store"), builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Self.makeStore(at: release, builtAt: Date(timeIntervalSince1970: 1_800_000_000))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, release), "\(discovered.path)")
    }

    /// A tie goes to the earlier candidate in `swiftPMCandidates`' order — the explicitly requested `.build/index/store` here, over `.build/out` and `.build/release/index/store` — rather than to whichever the loop saw last.
    ///
    /// Two stores whose newest units share one mtime are indistinguishable by the rule, so the order is all that decides, and it has to decide the same way every time.
    @Test
    func anEarlierCandidateKeepsATie() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let built = Date(timeIntervalSince1970: 1_800_000_000)
        let requested = root.appendingPathComponent(".build/index/store")
        try Self.makeStore(at: requested, builtAt: built)
        try Self.makeStore(at: root.appendingPathComponent(".build/out"), builtAt: built)
        try Self.makeStore(at: root.appendingPathComponent(".build/release/index/store"), builtAt: built)
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, requested), "a tie must go to the earlier candidate: \(discovered.path)")
    }

    @Test
    func buildServerWorkspaceMatchesDerivedDataEntry() throws {
        let root = try Self.makeRepo()
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        let entry = derivedData.appendingPathComponent("App-abcdef")
        let store = entry.appendingPathComponent("Index.noindex/DataStore")
        try Self.makeStore(at: store)
        let workspacePath = root.appendingPathComponent("Apps/App.xcodeproj/project.xcworkspace").path
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        let plist: [String: Any] = ["WorkspacePath": workspacePath]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: entry.appendingPathComponent("info.plist"))
        let buildServer = ["workspace": "Apps/App.xcodeproj/project.xcworkspace"]
        try JSONSerialization.data(withJSONObject: buildServer)
            .write(to: root.appendingPathComponent("buildServer.json"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .buildServerJSON)
        #expect(discovered.path.path.hasSuffix("Index.noindex/DataStore"))
    }

    @Test
    func derivedDataScanMatchesWorkspacesInsideTheRepo() throws {
        let root = try Self.makeRepo()
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        try Self.makeEntry(named: "App-abcdef", in: derivedData, workspace: root.appendingPathComponent("App.xcodeproj"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .derivedData)
    }

    /// `contentsOfDirectory(at:)` enumerates as empty through a symlink to a directory — the same class of bug `BuildFileScan` already guards against for a symlinked module tree — so a `DerivedData` moved aside and replaced with a symlink must not read as "nothing here".
    @Test
    func aSymlinkedDerivedDataDirectoryStillEnumerates() throws {
        let root = try Self.makeRepo()
        let realDerivedData = root.appendingPathComponent("RealDerivedData")
        try Self.makeEntry(named: "App-abcdef", in: realDerivedData, workspace: root.appendingPathComponent("App.xcodeproj"))
        let linkedDerivedData = root.appendingPathComponent("LinkedDerivedData")
        try FileManager.default.createSymbolicLink(at: linkedDerivedData, withDestinationURL: realDerivedData)
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: linkedDerivedData)

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .derivedData)
    }

    /// A workspace in a subdirectory of the root, with no checkout nested between them, is this repository's own — the nested-checkout walk stops short of the root's own `.git`.
    @Test
    func derivedDataScanMatchesAWorkspaceInASubdirectory() throws {
        let root = try Self.makeRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        let store = try Self.makeEntry(named: "App-abcdef", in: derivedData, workspace: root.appendingPathComponent("Apps/App.xcodeproj"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, store), "\(discovered.path)")
    }

    @Test
    func nothingFoundIsNil() throws {
        let root = try Self.makeRepo()
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        #expect(discovery.discover() == nil)
    }

    /// A configured `indexStorePath` that is just a build root, not the store itself — the shape a nested SwiftPM package's `.build` produces — must not be accepted: doing so anchors staleness at `.distantPast` and turns every occurrence into a false "changed since last build".
    @Test
    func aConfiguredPathThatIsNotAStoreShapeIsRejected() throws {
        let root = try Self.makeRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pkg/.build"), withIntermediateDirectories: true)
        var config = SiftConfig()
        config.indexStorePath = "Pkg/.build"
        let discovery = IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd"))

        #expect(discovery.discover() == nil)
    }

    /// The parent checkout must never borrow a linked worktree's own DerivedData entry: at a different commit that store would name callers that do not exist in the parent and miss ones that do.
    @Test
    func derivedDataScanNeverBorrowsANestedWorktreesStore() throws {
        let root = try Self.makeRepo()
        let worktree = try Self.makeWorktree(at: "worktrees/agent-1a2b3c4d", under: root)
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        try Self.makeEntry(named: "App-abcdef", in: derivedData, workspace: worktree.appendingPathComponent("App.xcodeproj"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        #expect(discovery.discover() == nil, "the parent must not borrow the worktree's own store")
    }

    /// The same fixture, discovered from the worktree's own root, finds the entry the parent must not.
    @Test
    func derivedDataScanFindsAWorktreesOwnStore() throws {
        let root = try Self.makeRepo()
        let worktree = try Self.makeWorktree(at: "worktrees/agent-1a2b3c4d", under: root)
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        try Self.makeEntry(named: "App-abcdef", in: derivedData, workspace: worktree.appendingPathComponent("App.xcodeproj"))
        let discovery = IndexStoreDiscovery(repoRoot: worktree, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(discovered.provenance == .derivedData)
    }

    /// A root spelled through a symlinked directory still finds the entry recorded under another spelling of the same path, in both directions.
    ///
    /// Xcode writes `WorkspacePath` its own way (a scratch repository under `/private/tmp` is recorded as `/tmp/…`), and a root arrives however its caller spelled it — through `/tmp`, or in a shell's case-folded spelling — so a raw prefix match misses this repository's own store and answers "none found" beside it.
    @Test
    func aRootSpelledThroughASymlinkStillFindsItsOwnStore() throws {
        let container = try Self.makeRepo()
        let realParent = container.appendingPathComponent("Real")
        let real = realParent.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linkParent = container.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linkParent, withDestinationURL: realParent)
        let linked = linkParent.appendingPathComponent("Repo")
        let derivedData = container.appendingPathComponent("FakeDerivedData")
        let store = try Self.makeEntry(named: "App-real", in: derivedData, workspace: real.appendingPathComponent("Apps/App.xcodeproj"))
        let recordedThroughLink = container.appendingPathComponent("second/FakeDerivedData")
        let linkedStore = try Self.makeEntry(named: "App-link", in: recordedThroughLink, workspace: linked.appendingPathComponent("Apps/App.xcodeproj"))

        let throughLink = IndexStoreDiscovery(repoRoot: linked, config: SiftConfig(), derivedDataRoot: derivedData).discover()
        let fromReal = IndexStoreDiscovery(repoRoot: real, config: SiftConfig(), derivedDataRoot: recordedThroughLink).discover()

        #expect(throughLink.map { Self.same($0.path, store) } == true, "\(String(describing: throughLink))")
        #expect(fromReal.map { Self.same($0.path, linkedStore) } == true, "\(String(describing: fromReal))")
    }

    /// A removed worktree's entry outlives it — Xcode keeps DerivedData after `git worktree remove` deletes the folder, `.git` file and all — and must not be borrowed back by the parent, even though it is the newest.
    ///
    /// With the folder gone, nothing marks the path as a nested checkout any more, so it reads as a workspace in a plain subdirectory; the parent's own, older store was on disk the whole time.
    @Test
    func derivedDataScanNeverBorrowsARemovedWorktreesStore() throws {
        let root = try Self.makeRepo()
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        let parentStore = try Self.makeEntry(
            named: "App-parent",
            in: derivedData,
            workspace: root.appendingPathComponent("Apps/App.xcodeproj"),
            builtAt: Date(timeIntervalSinceNow: -3600)
        )
        let worktree = try Self.makeWorktree(at: "worktrees/w1", under: root)
        try Self.makeEntry(named: "App-worktree", in: derivedData, workspace: worktree.appendingPathComponent("Apps/App.xcodeproj"), builtAt: Date())
        try FileManager.default.removeItem(at: worktree)
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, parentStore), "the removed worktree's newer entry must not win: \(discovered.path)")
    }

    /// A workspace under a hidden directory is in a tree the index never covers — `.claude/worktrees` is where agent worktrees live — so its store is never this repository's, even with no `.git` left to mark it.
    @Test
    func derivedDataScanNeverBorrowsAStoreUnderAHiddenDirectory() throws {
        let root = try Self.makeRepo()
        let derivedData = root.appendingPathComponent("FakeDerivedData")
        let parentStore = try Self.makeEntry(
            named: "App-parent",
            in: derivedData,
            workspace: root.appendingPathComponent("Apps/App.xcodeproj"),
            builtAt: Date(timeIntervalSinceNow: -3600)
        )
        try Self.makeEntry(
            named: "App-hidden",
            in: derivedData,
            workspace: root.appendingPathComponent(".claude/worktrees/w1/Apps/App.xcodeproj"),
            builtAt: Date()
        )
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, parentStore), "\(discovered.path)")
    }

    /// Only the path below the root is judged hidden: a worktree whose own root sits under `.claude/worktrees` still finds its own entry.
    @Test
    func aWorktreeRootedUnderAHiddenDirectoryFindsItsOwnStore() throws {
        let container = try Self.makeRepo()
        let worktree = try Self.makeWorktree(at: ".claude/worktrees/w1", under: container)
        let derivedData = container.appendingPathComponent("FakeDerivedData")
        let store = try Self.makeEntry(named: "App-w1", in: derivedData, workspace: worktree.appendingPathComponent("Apps/App.xcodeproj"))
        let discovery = IndexStoreDiscovery(repoRoot: worktree, config: SiftConfig(), derivedDataRoot: derivedData)

        let discovered = try #require(discovery.discover())

        #expect(Self.same(discovered.path, store), "\(discovered.path)")
    }

    /// The shape check and the staleness anchor accept the same versions: a `v6` store is found *and* anchored at its own unit, never at `.distantPast`, which would read as permanently stale.
    ///
    /// With several versions present both read the highest, compared as a number — `v10` over `v9`, and over a `v5` whose unit happens to be newer.
    @Test
    func theStoreVersionIsReadTheSameWayByTheCheckAndTheAnchor() throws {
        let root = try Self.makeRepo()
        let built = Date(timeIntervalSince1970: 1_800_000_000)
        try Self.makeStore(at: root.appendingPathComponent(".build/index/store"), version: "v6", builtAt: built)
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))

        let discovered = try #require(discovery.discover())

        #expect(IndexStoreDiscovery.newestUnitDate(in: discovered.path) == built)

        let several = root.appendingPathComponent("several")
        try Self.makeStore(at: several, version: "v5", builtAt: Date(timeIntervalSince1970: 1_900_000_000))
        try Self.makeStore(at: several, version: "v9", builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Self.makeStore(at: several, version: "v10", builtAt: built)
        #expect(IndexStoreDiscovery.newestUnitDate(in: several) == built)
    }

    /// A `buildServer.json` `indexStorePath` that is not a store is reported, as the `.sift.json` one is — naming the file that set it.
    @Test
    func aRejectedSettingIsNamedWithTheFileThatSetIt() throws {
        let root = try Self.makeRepo()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pkg/.build"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["indexStorePath": "Pkg/.build"])
            .write(to: root.appendingPathComponent("buildServer.json"))
        var config = SiftConfig()
        config.indexStorePath = ".build/debug/index/store"
        try Self.makeStore(at: root.appendingPathComponent("custom/store"))
        let discovery = IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd"))

        #expect(discovery.rejectedSettings() == [
            "indexStorePath '.build/debug/index/store' in .sift.json is not an index store (no v<N>/units under it)",
            "indexStorePath 'Pkg/.build' in buildServer.json is not an index store (no v<N>/units under it)",
        ])

        config.indexStorePath = "custom/store"
        let accepted = IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd"))
        #expect(accepted.rejectedSettings() == [
            "indexStorePath 'Pkg/.build' in buildServer.json is not an index store (no v<N>/units under it)",
        ])
    }

    /// The newest unit is found across a synthetic multi-file store with nested subdirectories — a real store's `v<N>/units` sits flat, but the walk must still ignore a directory's own mtime and count regular files only, which the single-file fixture `makeStore` seeds every other test with cannot exercise.
    ///
    /// Both file dates sit well in the past, so the directories this fixture creates along the way — stamped with today's date by the filesystem — are newer than either. A walk that let a directory's own mtime into the max would answer with today rather than with the newer file's date; only a walk that maxes over files alone gets this right.
    @Test
    func newestUnitDateFindsTheMaxAcrossFilesAndNestedDirectories() throws {
        let root = try Self.makeRepo()
        let store = root.appendingPathComponent("Index.noindex/DataStore")
        let units = store.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units.appendingPathComponent("aa"), withIntermediateDirectories: true)

        let older = units.appendingPathComponent("older")
        let newer = units.appendingPathComponent("aa/newer")
        try Data("older".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000) // years before this test runs
        let newDate = Date(timeIntervalSince1970: 1_750_000_000) // newer than oldDate, still years before this test runs
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newer.path)

        let found = try #require(IndexStoreDiscovery.newestUnitDate(in: store))

        #expect(Swift.abs(found.timeIntervalSince1970 - newDate.timeIntervalSince1970) < 1)
    }
}
