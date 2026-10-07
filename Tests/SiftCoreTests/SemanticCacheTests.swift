//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
@testable import SiftCore
import Testing

/// Which caches under `.sift/isdb` an open keeps and which it reclaims, and what the engine remembers per cache — over fabricated stores (Docs/Design.md §2).
@Suite(.temporaryDirectories)
struct SemanticCacheTests {
    /// A pid no process can have: macOS never hands out one above 99,998.
    private static let deadProcess: pid_t = 99_999_999

    /// A store's shape with one unit in it — enough for discovery's check and for the cache's identity.
    private static func makeStore(at url: URL) throws {
        let unit = url.appendingPathComponent("v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: unit)
    }

    /// The private copy IndexStoreDB moves a database into while `pid` has it open, named as it names them, under `directory`.
    private static func makeCopy(heldBy pid: pid_t, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("p\(pid)-abc123"), withIntermediateDirectories: true)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// A store's cache stays while the store exists, so switching back to it finds it warm, and goes at the next open once the store is gone.
    @Test
    func aCacheStaysWhileItsStoreExistsAndGoesOnceTheStoreIsGone() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try Self.makeStore(at: first)
        try Self.makeStore(at: second)
        let firstCache = try #require(SemanticCache(store: first, in: cacheRoot))
        let secondCache = try #require(SemanticCache(store: second, in: cacheRoot))

        try firstCache.prepare()
        try secondCache.prepare()
        let whileBothExist = Self.exists(firstCache.directory)
        try FileManager.default.removeItem(at: first)
        try secondCache.prepare()

        #expect(firstCache.directory != secondCache.directory)
        #expect(whileBothExist, "a store that still exists keeps its cache")
        #expect(!Self.exists(firstCache.directory), "the cache of a store that is gone is reclaimed")
        #expect(Self.exists(secondCache.directory))
    }

    /// One store is one cache, whether it is named before its directory exists or after.
    ///
    /// The engine reuses an open layer, and a remembered failed open, only while discovery yields an equal cache. Were equality to depend on the directory having been created — Foundation, left to look, adds a trailing slash to a path component once there is a directory to find — the cache named for the first open would never equal the one named for every query after it.
    @Test
    func aStoreIsOneCacheBeforeAndAfterItsDirectoryExists() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        let beforeItsFirstOpen = try #require(SemanticCache(store: store, in: cacheRoot))
        try beforeItsFirstOpen.prepare()

        let afterIt = try #require(SemanticCache(store: store, in: cacheRoot))

        #expect(afterIt == beforeItsFirstOpen, "\(afterIt.directory) != \(beforeItsFirstOpen.directory)")
    }

    /// A store deleted and made again at the same path gets a cache of its own, and the deleted store's goes.
    ///
    /// The engine-level case, with really-built stores, is in `SemanticCacheIsolationTests`; this is the property it rests on, that the key is not the path alone.
    @Test
    func aStoreMadeAgainAtTheSamePathGetsACacheOfItsOwn() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        let deleted = try #require(SemanticCache(store: store, in: cacheRoot))
        try deleted.prepare()
        try FileManager.default.removeItem(at: store)
        try Self.makeStore(at: store)

        let remade = try #require(SemanticCache(store: store, in: cacheRoot))
        try remade.prepare()

        #expect(remade.storePath == deleted.storePath)
        #expect(remade.directory != deleted.directory, "a store made again at one path must not reopen the deleted one's cache")
        #expect(!Self.exists(deleted.directory), "the deleted store's cache is reclaimed")
    }

    /// The key is the store's path and its units directory's inode and creation time — not the device, which a disk image or an external disk can come back under another number of at its next mount.
    ///
    /// Were the device in it, every store on such a disk would get a new key at each mount and be re-imported for nothing, minutes a store on a monorepo. The device cannot be varied in a test, so the key is asked of the directory's own `stat` with only the device changed — and, as the control, with only the inode or only the creation time changed, each of which is another directory.
    @Test
    func theKeyIsTheInodeAndCreationTimeAndNeverTheDevice() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        var units = stat()
        try #require(stat(store.appendingPathComponent("v5/units").path, &units) == 0)
        let canonical = CanonicalPath.of(store.path)
        var remounted = units
        remounted.st_dev &+= 1
        var anotherInode = units
        anotherInode.st_ino &+= 1
        var bornLater = units
        bornLater.st_birthtimespec.tv_sec += 1
        let cache = try #require(SemanticCache(store: store, in: base.appendingPathComponent("repo/.sift")))

        let key = SemanticCache.key(store: canonical, units: units)

        #expect(cache.directory.lastPathComponent == key, "the cache is named by this key")
        #expect(SemanticCache.key(store: canonical, units: remounted) == key, "a store on a disk mounted under another device number is the same store")
        #expect(SemanticCache.key(store: canonical, units: anotherInode) != key)
        #expect(SemanticCache.key(store: canonical, units: bornLater) != key)
    }

    /// A cache a running process holds open is never reclaimed — a store's own whose store is gone, or the flat one an earlier version kept — while a flat one only a dead process's copy is left in is emptied, its directory kept for an earlier version to open.
    ///
    /// IndexStoreDB gives each process its own copy of the database while it is open and moves it back on close; deleting a live copy's directory is what reclamation must never do to another process.
    @Test
    func aCacheARunningProcessHoldsIsNeverReclaimed() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let isdb = SemanticCache.root(in: cacheRoot)
        let gone = base.appendingPathComponent("gone")
        let current = base.appendingPathComponent("current")
        try Self.makeStore(at: gone)
        try Self.makeStore(at: current)
        let goneCache = try #require(SemanticCache(store: gone, in: cacheRoot))
        try goneCache.prepare()
        try Self.makeCopy(heldBy: getpid(), in: goneCache.directory.appendingPathComponent("v13"))
        try FileManager.default.removeItem(at: gone)
        let heldFlat = isdb.appendingPathComponent("v13")
        try Self.makeCopy(heldBy: getpid(), in: heldFlat)
        let abandonedFlat = isdb.appendingPathComponent("v12")
        try FileManager.default.createDirectory(at: abandonedFlat.appendingPathComponent("saved"), withIntermediateDirectories: true)
        try Self.makeCopy(heldBy: Self.deadProcess, in: abandonedFlat)

        try #require(SemanticCache(store: current, in: cacheRoot)).prepare()

        #expect(Self.exists(goneCache.directory), "a running process still has the gone store's cache open")
        #expect(Self.exists(heldFlat.appendingPathComponent("p\(getpid())-abc123")), "a running process still has the flat cache's copy open")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: abandonedFlat.path)) == [],
            "a flat cache only a dead process's copy is left in is emptied, and the directory an earlier version opens is kept"
        )
    }

    /// A cache being made is never reclaimed from under its maker, and one whose maker died is.
    ///
    /// Another process reclaiming in the instant between a cache's directory appearing and its `store` file being written found a cache naming no store and deleted it, and the maker's open then failed — remembered as failed, by a server until the next build or until it restarts. So a cache is made under a name reclamation passes over while its maker runs, and renamed into place already marked. The reclaimer here runs in exactly that instant, through the seam `prepare` leaves for it, rather than in a race a test could only hope to hit.
    @Test
    func aCacheBeingMadeIsNeverReclaimedFromUnderItsMaker() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let isdb = SemanticCache.root(in: cacheRoot)
        let mine = base.appendingPathComponent("mine")
        let other = base.appendingPathComponent("other")
        try Self.makeStore(at: mine)
        try Self.makeStore(at: other)
        let cache = try #require(SemanticCache(store: mine, in: cacheRoot))
        let reclaimer = try #require(SemanticCache(store: other, in: cacheRoot))
        try FileManager.default.createDirectory(at: isdb.appendingPathComponent("making-\(Self.deadProcess)-abc123"), withIntermediateDirectories: true)

        try cache.prepare(whileMaking: { try reclaimer.prepare() })
        let marker = try String(contentsOf: cache.directory.appendingPathComponent(SemanticCache.markerName), encoding: .utf8)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: isdb.path))

        #expect(marker == "\(cache.storePath)\n", "the cache came into place marked with its store")
        #expect(
            left == [cache.directory.lastPathComponent, reclaimer.directory.lastPathComponent],
            "nothing half-made is left behind, this process's or a dead one's"
        )
    }

    /// A cache whose only copy is one IndexStoreDB marked `-dead` is reclaimed once its store is gone, even while the pid in that copy's name is running.
    ///
    /// IndexStoreDB moves a database it displaced on close to `p<pid>-…-saved-dead`, which no process holds. Read as a live copy, it kept the cache of a store that was gone for as long as the process that closed it last ran — a server, for the length of a session — and no process opens a gone store's cache again, so IndexStoreDB's own sweep never reaches it. The pid here is this test's own, which is running.
    @Test
    func aCacheLeftOnlyADeadCopyIsReclaimedWhileThatCopysProcessRuns() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let gone = base.appendingPathComponent("gone")
        let current = base.appendingPathComponent("current")
        try Self.makeStore(at: gone)
        try Self.makeStore(at: current)
        let goneCache = try #require(SemanticCache(store: gone, in: cacheRoot))
        try goneCache.prepare()
        let deadCopy = goneCache.directory.appendingPathComponent("v13/p\(getpid())-abc123-saved-dead")
        try FileManager.default.createDirectory(at: deadCopy, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: gone)

        try #require(SemanticCache(store: current, in: cacheRoot)).prepare()

        #expect(!Self.exists(goneCache.directory), "a -dead copy holds nothing, whatever pid its name carries")
    }

    /// A failed open is remembered for the store that failed, not for whichever store discovery yields next.
    ///
    /// It is remembered so the next query does not pay for it again. Keyed on the anchor alone, a newer store that failed to open went on refusing for an older one discovery moved to once the newer was gone, until a build newer than the failed one. The failure is a real one: a regular file where the failing store's cache has to be created.
    @Test
    func aFailedOpenIsRememberedForItsOwnStoreOnly() async throws {
        let root = try TestSources.makeTempRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSources.write("func helper() {}", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "one declaration")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let failing = root.appendingPathComponent(".build/out")
        try Self.makeStore(at: failing)
        let blocked = try #require(SemanticCache(store: failing, in: SiftPaths.cache(in: root)))
        try FileManager.default.createDirectory(at: blocked.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked.directory)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let failed = try await engine.lookup(symbol: "helper()", freshness: freshness)
        try FileManager.default.removeItem(at: failing)
        let moved = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(failed.contains("but failed to open:"), "\(failed)")
        #expect(!moved.contains("failed to open"), "the failure belongs to .build/out, which is gone: \(moved)")
    }

    /// A directory the rename into place loses to is marked with its store, never taken as made.
    ///
    /// IndexStoreDB makes `<key>/v<N>` for itself as it opens, so an open of a key another process has just reclaimed makes that directory again, bare. Taken as made, it named no store, and the next reclaimer removed it from under the open that took it. The bare directory appears here in the instant a real open would have to make it, through the seam `prepare` leaves between the marking and the rename.
    @Test
    func aDirectoryTheRenameIntoPlaceLosesToIsMarkedWithItsStore() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let mine = base.appendingPathComponent("mine")
        let other = base.appendingPathComponent("other")
        try Self.makeStore(at: mine)
        try Self.makeStore(at: other)
        let cache = try #require(SemanticCache(store: mine, in: cacheRoot))
        let openMadeItBare = { try FileManager.default.createDirectory(at: cache.directory.appendingPathComponent("v13"), withIntermediateDirectories: true) }

        try cache.prepare(whileMaking: openMadeItBare)
        try #require(SemanticCache(store: other, in: cacheRoot)).prepare()
        let marker = try? String(contentsOf: cache.directory.appendingPathComponent(SemanticCache.markerName), encoding: .utf8)

        #expect(marker == "\(cache.storePath)\n", "the directory the rename lost to is marked with its store")
        #expect(Self.exists(cache.directory), "a reclaimer keeps the cache of a store that is there")
    }

    /// A directory that goes between being found and being marked is made again, never a failed open.
    ///
    /// A reclaimer's discard, or another process's open setting the cache aside, can take the directory in the instant after an open finds it — there already, or there when the rename into place loses to it — and before its marker is written. Thrown, that failed the open, and the engine remembered the failure for a store that is there. The directory goes here in that instant, through the seam `prepare` leaves before the marking, for a cache found there and for one the rename lost to because an open had made it bare.
    @Test
    func aDirectoryGoneBeforeItIsMarkedIsMadeAgain() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let found = base.appendingPathComponent("found")
        let lost = base.appendingPathComponent("lost")
        try Self.makeStore(at: found)
        try Self.makeStore(at: lost)
        let foundCache = try #require(SemanticCache(store: found, in: cacheRoot))
        let lostCache = try #require(SemanticCache(store: lost, in: cacheRoot))
        try FileManager.default.createDirectory(at: foundCache.directory, withIntermediateDirectories: true)
        var taken: [URL] = []
        func takeOnce(_ cache: SemanticCache) throws {
            guard !taken.contains(cache.directory) else { return }
            taken.append(cache.directory)
            try FileManager.default.removeItem(at: cache.directory)
        }

        try foundCache.prepare(beforeMarking: { try takeOnce(foundCache) })
        try lostCache.prepare(
            whileMaking: { try FileManager.default.createDirectory(at: lostCache.directory.appendingPathComponent("v13"), withIntermediateDirectories: true) },
            beforeMarking: { try takeOnce(lostCache) }
        )

        #expect(taken == [foundCache.directory, lostCache.directory], "each directory went before it was marked")
        for cache in [foundCache, lostCache] {
            let marker = try? String(contentsOf: cache.directory.appendingPathComponent(SemanticCache.markerName), encoding: .utf8)
            #expect(marker == "\(cache.storePath)\n", "made again, marked with its store: \(cache.storePath)")
        }
    }

    /// What a dead maker left half-made is reclaimed even once another process has its pid, and what a running maker is making is kept.
    ///
    /// Judged by the pid alone, a half-made directory stayed until whatever process took the pid exited. The name carries the maker's start time too, which a process that reuses the pid cannot share. The pid here is this test's own, which is running: under a start time it never had, it stands for a reused pid, and under its own, for a maker still making its cache. A name with no start time, as an earlier version writes, is judged by its pid alone.
    @Test
    func whatADeadMakerLeftIsReclaimedEvenOnceItsPidIsReused() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let isdb = SemanticCache.root(in: cacheRoot)
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        let started = try #require(KernelProcess.startMicroseconds(of: getpid()))
        let reused = isdb.appendingPathComponent("making-\(getpid())-t\(started - 1)-abc123")
        let running = isdb.appendingPathComponent("making-\(getpid())-t\(started)-abc123")
        let earlierVersion = isdb.appendingPathComponent("making-\(getpid())-ABC123")
        for making in [reused, running, earlierVersion] {
            try FileManager.default.createDirectory(at: making, withIntermediateDirectories: true)
        }

        try #require(SemanticCache(store: store, in: cacheRoot)).prepare()

        #expect(!Self.exists(reused), "a pid another process has now keeps nothing its dead maker left")
        #expect(Self.exists(running), "a maker still running keeps what it is making")
        #expect(Self.exists(earlierVersion), "an earlier version's name, with no start time, is judged by its pid")
    }

    /// A maker whose start time cannot be read is judged by its pid, so a live one keeps what it is making.
    ///
    /// Compared with a start time that came back empty, every such maker read as dead, and a live one's directory was reclaimed from under it: its rename into place then had nothing to fall back on, and its open failed and was remembered. No read fails for an unsandboxed process, so the reader here is a stand-in that returns nothing. The running pid is this test's own; the dead one is a pid no process can have.
    @Test
    func aMakerWhoseStartTimeCannotBeReadIsJudgedByItsPid() throws {
        let started = try #require(KernelProcess.startMicroseconds(of: getpid()))
        let unreadable: (pid_t) -> UInt64? = { _ in nil }

        #expect(SemanticCache.isBeingMade(named: "making-\(getpid())-t\(started)-abc123", startOf: unreadable), "a running maker keeps what it is making")
        #expect(!SemanticCache.isBeingMade(named: "making-\(Self.deadProcess)-t\(started)-abc123", startOf: unreadable), "a dead maker's is reclaimed")
    }

    /// A cache that cannot be renamed aside loses this process's copy in place, so the open's close has nothing to move back — and only this process's copy: another process's copy under the same cache is left for its own close to find.
    ///
    /// An open whose store was replaced while it read sets its cache aside by renaming it out from under itself. When that rename failed — a directory the caches sit in that cannot be written, as here, or an immutable flag — the open threw all the same, and IndexStoreDB's close moved its copy, holding the other store's units, back to `saved`, where the store the key names would read it as its own should it come back to its path. The copy is the one IndexStoreDB makes for this process; a copy under another pid is a different process's live database and is never this process's to remove.
    @Test
    func aCacheThatCannotBeRenamedAsideLosesThisProcesssCopyInPlace() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let isdb = SemanticCache.root(in: cacheRoot)
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        let cache = try #require(SemanticCache(store: store, in: cacheRoot))
        try cache.prepare()
        let versionDirectory = cache.directory.appendingPathComponent("v13")
        let copy = versionDirectory.appendingPathComponent("p\(getpid())-abc123")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("mixed".utf8).write(to: copy.appendingPathComponent("data.mdb"))
        try Self.makeCopy(heldBy: Self.deadProcess, in: versionDirectory)
        let otherProcessCopy = versionDirectory.appendingPathComponent("p\(Self.deadProcess)-abc123")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: isdb.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: isdb.path) }

        cache.setAside()

        #expect(Self.exists(cache.directory), "the cache could not be renamed aside")
        #expect(!Self.exists(copy), "this process's copy went in its place, so the close has nothing to move back to saved")
        #expect(Self.exists(otherProcessCopy), "another process's copy is not this process's to remove, so it survives")
    }

    /// A cache an earlier per-store version named is never opened, and is reclaimed like any cache whose store has another key now.
    ///
    /// That version named a cache for its store's path and units directory alone, and never read the key again once its open's read ended: a server of it that read a store replaced mid-import wrote the copy it filled with both stores' units back under the old store's key, which the store brings back when it is moved away and back. Opened here, that copy answered `fresh` from the other store's units. The earlier key is computed as that version computed it, and its cache is marked with its store as that version marked it.
    @Test
    func aCacheAnEarlierPerStoreVersionNamedIsNeverOpenedAndIsReclaimed() throws {
        let base = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("repo/.sift")
        let store = base.appendingPathComponent("store")
        try Self.makeStore(at: store)
        var units = stat()
        try #require(stat(store.appendingPathComponent("v5/units").path, &units) == 0)
        let canonical = CanonicalPath.of(store.path)
        let born = units.st_birthtimespec
        let identity = "\(units.st_ino):\(born.tv_sec).\(born.tv_nsec)"
        let earlierKey = SHA256.hash(data: Data("\(canonical)\n\(identity)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let earlier = SemanticCache.root(in: cacheRoot).appendingPathComponent(earlierKey)
        try FileManager.default.createDirectory(at: earlier.appendingPathComponent("v13/saved"), withIntermediateDirectories: true)
        try Data("\(canonical)\n".utf8).write(to: earlier.appendingPathComponent(SemanticCache.markerName))
        let cache = try #require(SemanticCache(store: store, in: cacheRoot))

        try cache.prepare()

        #expect(cache.directory.lastPathComponent != earlierKey, "an earlier version's key is never this version's")
        #expect(!Self.exists(earlier), "the earlier version's cache names a store whose key is another now, and is reclaimed")
        #expect(Self.exists(cache.directory), "the store's own cache is made")
    }
}
