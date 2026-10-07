//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A semantic cache answers only for the store it was filled from — through the engine, against really-built stores (Docs/Design.md §2).
///
/// Each case drops its first engine before the second one reads, as a finished CLI process or a restarted server does: IndexStoreDB keeps a cache it has open in a private copy and moves it back on close, so a closed cache is the one the next reader finds.
@Suite(.temporaryDirectories)
struct SemanticCacheIsolationTests {
    private static let native = ["--build-system", "native"]
    private static let swiftBuild = ["--build-system", "swiftbuild"]

    /// A package whose `Base.greet()` is called from `callGreet()` in `Sources/Lib/Caller.swift`, committed and not yet built.
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("open class Base {\n    public init() {}\n    open func greet() {}\n}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("public func callGreet() {\n    Base().greet()\n}\n", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "the call is in Caller.swift")
        return root
    }

    /// v2: `callGreet()` and its call move to `Sources/Lib/Moved.swift`, and `Caller.swift` calls nothing.
    private static func moveTheCall(in root: URL) throws {
        try TestSources.write("public func idle() {}\n", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.write("public func callGreet() {\n    Base().greet()\n}\n", to: "Sources/Lib/Moved.swift", in: root)
        try TestSources.commitAll(in: root, message: "the call moved to Moved.swift")
    }

    /// What `where` says about `Base.greet()` from an engine of its own, dropped — its cache closed — before this returns.
    private static func greetAnswer(in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: "Base.greet", freshness: engine.ensureFresh())
    }

    /// The v2 answer: fresh, with one caller, in the file the call moved to.
    private static func expectOnlyTheMovedCall(_ answer: String, _ leak: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(answer.contains("semantic: fresh"), "\(answer)", sourceLocation: sourceLocation)
        #expect(answer.contains("callers of Lib.Base.greet() (1):"), "\(leak): \(answer)", sourceLocation: sourceLocation)
        #expect(WhereStoreSiteTextTests.located(answer).contains("Sources/Lib/Moved.swift:2"), "\(answer)", sourceLocation: sourceLocation)
        #expect(!WhereStoreSiteTextTests.located(answer).contains("Sources/Lib/Caller.swift:2"), "\(leak): \(answer)", sourceLocation: sourceLocation)
    }

    /// Discovery moving from Swift Build's `.build/out` to a newer native store must leave the first store's units behind.
    ///
    /// The native store is built at v1 before `.build/out` is, as a checkout that predates the upgrade to Swift Build has one, so it still holds the record the v1 call wrote when the v2 build lands in it — the record a unit left from `.build/out` names. With one cache for every store, that unit answered `fresh` with a call `Caller.swift` no longer makes.
    @Test
    func aStoreDiscoveryMovedAwayFromNeverAnswersForTheOneItMovedTo() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.swiftBuild)
        try #require(IndexStoreDiscovery.isStore(root.appendingPathComponent(".build/out")), "Swift Build writes its store at .build/out")
        let first = try await Self.greetAnswer(in: root)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)

        let moved = try await Self.greetAnswer(in: root)

        #expect(WhereStoreSiteTextTests.located(first).contains("Sources/Lib/Caller.swift:2"), "the v1 answer lists the call: \(first)")
        Self.expectOnlyTheMovedCall(moved, "a unit from .build/out answered for the native store")
    }

    /// A store deleted and rebuilt at the same path is another store, and the cache the deleted one filled must not answer for it.
    ///
    /// The path cannot tell the two apart; the directory's identity in the key can. The deleted store's release build left a unit in its cache; the rebuilt store's first debug build, at v1, writes the record that unit names under a unit of its own, and the v2 build after it leaves the record in place — so with the path alone for a key, the release unit answered `fresh` with the v1 call.
    @Test
    func aStoreRebuiltAtTheSamePathNeverInheritsTheDeletedOnesUnits() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])
        let first = try await Self.greetAnswer(in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)

        let rebuilt = try await Self.greetAnswer(in: root)

        #expect(WhereStoreSiteTextTests.located(first).contains("Sources/Lib/Caller.swift:2"), "the v1 answer lists the call: \(first)")
        Self.expectOnlyTheMovedCall(rebuilt, "a unit from the deleted store answered for the one rebuilt in its place")
    }

    /// A store replaced while its open reads it never answers from the cache named for the store it replaced.
    ///
    /// The cache is named before the open, and IndexStoreDB reads the store during it — a cold import that can run for minutes — so `rm -rf .build && swift build` landing in between fills the old store's cache with the new one's units beside its own. No real rebuild can be timed to land there, so the engine's hook swaps the store as the open finishes: the v1 store is read, the v2 store takes its place at the same path, a directory of its own, and the answer must come from v2. The budget is wide so the open of the store there now lands inside this query rather than warming.
    @Test
    func aStoreReplacedDuringItsOpenNeverAnswersFromTheCacheNamedForTheOneItReplaced() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let store = root.appendingPathComponent(".build/index/store")
        let storeV1 = root.appendingPathComponent(".build/store-v1")
        let storeV2 = root.appendingPathComponent(".build/store-v2")
        let read = root.appendingPathComponent(".build/store-read")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try manager.copyItem(at: store, to: storeV1)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try manager.moveItem(at: store, to: storeV2)
        try manager.moveItem(at: storeV1, to: store)
        let engine = try SiftEngine(directory: root)
        engine.openBudget = 300
        engine.afterSemanticOpen = {
            // Once: by the open of the store there now, there is nothing left to swap in.
            guard FileManager.default.fileExists(atPath: storeV2.path) else { return }
            try? FileManager.default.moveItem(at: store, to: read)
            try? FileManager.default.moveItem(at: storeV2, to: store)
        }

        let answer = try await engine.lookup(symbol: "Base.greet", freshness: engine.ensureFresh())

        Self.expectOnlyTheMovedCall(answer, "the cache named for the replaced v1 store answered")
    }

    /// The flat cache earlier versions kept, `.sift/isdb/v<N>`, is never read as the chosen store's, and is emptied.
    ///
    /// Filled from `.build/out` as an earlier version filled it, it holds exactly the leftover unit the first case is about, so the native store the v2 build moves discovery to has to answer without it. Emptied rather than removed: a process of an earlier version opens that directory with no lock, and one caught between making it and making its copy inside it would fail.
    @Test
    func aFlatCacheFromAnEarlierVersionIsNeverReadAndIsEmptied() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.swiftBuild)
        _ = try await Self.greetAnswer(in: root)
        let flat = try Self.flattenCache(in: root)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)

        let moved = try await Self.greetAnswer(in: root)

        #expect((try? FileManager.default.contentsOfDirectory(atPath: flat.path)) == [], "a flat cache nothing holds is emptied, its directory kept")
        Self.expectOnlyTheMovedCall(moved, "the flat cache's .build/out unit answered for the native store")
    }

    /// A store moved away and back never finds the cache an open set aside while the store was away, holding another store's units.
    ///
    /// The open is set aside because the store it named was replaced while it read, so its cache holds the replacement's units. Moving the store away and back (`mv store x; …; mv x store`) brings back its inode and creation time, and with them that cache's key. Here the replacement is a release build at v1, put in place as the open starts, as a rebuild landing then would. The store that comes back holds the v1 record that release unit names, so an open of the cache the set-aside open filled answered `fresh` with the v1 call beside the moved one.
    @Test
    func aStoreMovedAwayAndBackNeverFindsTheCacheAnOpenSetAsideFilledWithAnotherStoresUnits() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let store = root.appendingPathComponent(".build/index/store")
        let release = root.appendingPathComponent(".build/store-release")
        let away = root.appendingPathComponent(".build/store-away")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native + ["-c", "release"])
        try manager.moveItem(at: store, to: release)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        do {
            let engine = try SiftEngine(directory: root)
            engine.openBudget = 300
            engine.beforeSemanticRead = {
                // Once: by the open of the release store, there is nothing left to swap in.
                guard FileManager.default.fileExists(atPath: release.path) else { return }
                try? FileManager.default.moveItem(at: store, to: away)
                try? FileManager.default.moveItem(at: release, to: store)
            }
            _ = try await engine.lookup(symbol: "Base.greet", freshness: engine.ensureFresh())
        }
        try manager.moveItem(at: store, to: release)
        try manager.moveItem(at: away, to: store)

        let back = try await Self.greetAnswer(in: root)

        Self.expectOnlyTheMovedCall(back, "the cache the set-aside open filled from the release store answered for the store that came back")
    }

    /// An open set aside in the background, after its query answered warming, is opened again once its store is back — never remembered as failed.
    ///
    /// Past the budget an open goes on alone, and one whose store was replaced while it read settles set aside, its cache gone with the replacement's units. Should the store come back before the next query, moved away and back and its key with it, that key finds the outcome the set-aside open settled on — no failure of the store there now, which is opened afresh. A zero budget leaves the first open running whatever the machine's speed, and the replacement is a copy of the store, a directory of its own with the same units.
    @Test
    func anOpenSetAsideInTheBackgroundIsOpenedAgainOnceItsStoreIsBack() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let store = root.appendingPathComponent(".build/index/store")
        let copy = root.appendingPathComponent(".build/store-copy")
        let away = root.appendingPathComponent(".build/store-away")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try manager.copyItem(at: store, to: copy)
        let named = try #require(SemanticCache(store: store, in: SiftPaths.cache(in: root)))
        let engine = try SiftEngine(directory: root)
        engine.openBudget = 0
        engine.beforeSemanticRead = {
            guard FileManager.default.fileExists(atPath: copy.path) else { return }
            try? FileManager.default.moveItem(at: store, to: away)
            try? FileManager.default.moveItem(at: copy, to: store)
        }

        let warming = try await engine.lookup(symbol: "Base.greet", freshness: engine.ensureFresh())
        // The open has read the copy once the store is away, and is set aside once the cache named for the store is gone.
        let deadline = Date().addingTimeInterval(120)
        while !manager.fileExists(atPath: away.path) || manager.fileExists(atPath: named.directory.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!manager.fileExists(atPath: named.directory.path), "the open that read the copy set its cache aside")
        try manager.moveItem(at: store, to: copy)
        try manager.moveItem(at: away, to: store)
        engine.openBudget = 300
        let back = try await engine.lookup(symbol: "Base.greet", freshness: engine.ensureFresh())

        #expect(warming.contains("still warming"), "the first open was left running: \(warming)")
        #expect(!back.contains("failed to open"), "the set-aside open was remembered as the store's failure: \(back)")
        #expect(back.contains("semantic: fresh"), "\(back)")
        #expect(WhereStoreSiteTextTests.located(back).contains("Sources/Lib/Caller.swift:2"), "\(back)")
    }

    /// A real copy that cannot be renamed aside is gone before its close looks for it — the property `setAside()` claims, over a real `IndexStoreDB` open rather than a fabricated copy.
    ///
    /// The store is swapped for another real one before this open reads it, the same shape as any replaced-while-read store, so the open settles as replaced and sets its cache aside. Making `.sift/isdb` unwritable first, the way the fabricated-copy test does, fails that rename, so the open instead removes this process's own copy where it sits. What is left afterward is what a real close would otherwise have filled: with the copy already gone, there is nothing under `v13` for `IndexStoreDB`'s close to move back to `saved`.
    @Test
    func aRealCopyThatCannotBeRenamedAsideIsGoneBeforeItsCloseLooksForIt() async throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let store = root.appendingPathComponent(".build/index/store")
        let storeV1 = root.appendingPathComponent(".build/store-v1")
        let storeV2 = root.appendingPathComponent(".build/store-v2")
        let away = root.appendingPathComponent(".build/store-away")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try manager.copyItem(at: store, to: storeV1)
        try Self.moveTheCall(in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: Self.native)
        try manager.moveItem(at: store, to: storeV2)
        try manager.moveItem(at: storeV1, to: store)
        let cacheRoot = SiftPaths.cache(in: root)
        let isdb = SemanticCache.root(in: cacheRoot)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: isdb.path) }
        let cache = try #require(SemanticCache(store: store, in: cacheRoot))
        let discovered = DiscoveredStore(path: store, provenance: .swiftPMBuild, newestUnit: nil)

        do {
            _ = try SemanticStore(discovered: discovered, newestUnitDate: Date(), cache: cache) {
                try? manager.moveItem(at: store, to: away)
                try? manager.moveItem(at: storeV2, to: store)
                try? manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: isdb.path)
            }
            Issue.record("the store swapped out from under this open should have settled as replaced while read")
        } catch is SemanticStore.ReplacedWhileRead {
            // Expected: the swap made this open's cache unmatched, the same as any replaced-while-read store.
        }

        #expect(manager.fileExists(atPath: cache.directory.path), "the cache could not be renamed aside")
        #expect(
            !manager.fileExists(atPath: cache.directory.appendingPathComponent("v13/saved").path),
            "this process's copy was already gone, so the close had nothing to move back to saved"
        )
    }

    /// Moves the database the cache holds to where a flat cache kept it, `.sift/isdb/v<N>/saved`, with nothing else left under `.sift/isdb`, and returns that `v<N>`.
    ///
    /// Whichever layout filled it: a flat cache is already there.
    private static func flattenCache(in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let manager = FileManager.default
        let isdb = SiftPaths.cache(in: root).appendingPathComponent("isdb")
        let databases = manager.enumerator(at: isdb, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
        let saved = try #require(
            databases.first { $0.lastPathComponent == "saved" },
            "the first engine closed its cache into saved: \(databases)",
            sourceLocation: sourceLocation
        )
        let version = saved.deletingLastPathComponent()
        let flat = isdb.appendingPathComponent(version.lastPathComponent)
        guard CanonicalPath.of(version.path) != CanonicalPath.of(flat.path) else { return flat }
        let aside = SiftPaths.cache(in: root).appendingPathComponent("flat-aside")
        try manager.moveItem(at: version, to: aside)
        try manager.removeItem(at: isdb)
        try manager.createDirectory(at: isdb, withIntermediateDirectories: true)
        try manager.moveItem(at: aside, to: flat)
        return flat
    }
}
