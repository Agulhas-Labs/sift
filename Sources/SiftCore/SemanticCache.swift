//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// Where one index store is ingested: a database directory of its own under `.sift/isdb`, named for the layout, the store's canonical path, and the identity of its units directory (Docs/Design.md §2).
///
/// IndexStoreDB never forgets a unit. Opening a cache adds and updates what the store holds, but a removal is raised only for a unit seen to vanish while that cache was open, and the list it is judged by starts empty on every open. So a cache that ever held another store's units keeps them, and a leftover unit resolves against any record the chosen store holds under the same name — a record is named for a hash of its content, so the same source built twice writes the same one — to answer `fresh` for code the tree no longer has. Discovery moving between stores (Swift Build's `.build/out`, then a `--build-system native` build) did that, and so did a store deleted and rebuilt at one path (`rm -rf .build`, `swift package clean`): the path tells the first apart, the directory's identity the second.
///
/// A cache is never emptied to be reused. A store that changes identity gets a new key, and the old directory is abandoned under one no process computes again unless that store comes back, when it is that store's own still, then reclaimed once nothing holds it. The one exception is a cache an open filled while its store was replaced, which holds another store's units under that key and is discarded at once (``setAside()``).
struct SemanticCache: Equatable {
    /// The file in each cache naming the store it was filled from — how reclamation tells a live store's cache from a dead one's.
    static var markerName: String {
        "store"
    }

    /// `<repo>/.sift/isdb/<key>` — the database directory IndexStoreDB is handed.
    let directory: URL
    /// The store as the filesystem spells it.
    let storePath: String

    /// The cache for `store` under `cacheRoot` (a repository's `.sift`), or `nil` when the store has no units directory to take an identity from — deleted since discovery saw it.
    ///
    /// The identity is the units directory's inode and creation time (``key(store:units:)``). It is the directory discovery's shape check and staleness anchor already read (``IndexStoreDiscovery/unitsDirectory(in:)``), so a store is one store to all three.
    init?(store: URL, in cacheRoot: URL) {
        let canonical = CanonicalPath.of(store.path)
        guard let units = IndexStoreDiscovery.unitsDirectory(in: URL(fileURLWithPath: canonical)) else { return nil }
        var status = stat()
        guard stat(units.path, &status) == 0 else { return nil }
        // Said to be a directory rather than asked: left to look, Foundation adds a trailing slash only once the
        // directory exists, and the cache computed before its first open would never equal the one after it.
        directory = Self.root(in: cacheRoot).appendingPathComponent(Self.key(store: canonical, units: status), isDirectory: true)
        storePath = canonical
    }

    /// The directory name for the store at `canonical` whose units directory `stat` described as `units`: a hash of the layout, the path, the inode and the creation time.
    ///
    /// The inode and the creation time are what a directory deleted and made again at the same path never shares with the one it replaced — an inode number reused for a later directory carries a later creation time. Not the device number: an external disk or a disk image can come back under another one at its next mount, which would change every key on it and re-import every store for nothing, and the canonical path already says where the store is. The layout (``layout``) keeps every cache an earlier per-store version named out of reach.
    static func key(store canonical: String, units: stat) -> String {
        let born = units.st_birthtimespec
        let identity = "\(units.st_ino):\(born.tv_sec).\(born.tv_nsec)"
        return SHA256.hash(data: Data("\(layout)\n\(canonical)\n\(identity)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The layout a key is made for, hashed into it: the second per-store layout, the first whose opens read their key again once their read ends.
    ///
    /// The first named its caches without it and had no such check, so a server of that version that read a store replaced mid-import wrote its copy, holding both stores' units, back under the old store's key — which that store brings back when it is moved away and back. Under keys that carry the layout, no cache of that version is ever opened: each names a store whose key is another now, and is reclaimed like any such cache once nothing holds it. A later layout changes this whenever caches this one writes could answer wrongly for it.
    private static var layout: String {
        "2"
    }

    /// `<repo>/.sift/isdb` — every store's cache.
    static func root(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent("isdb")
    }

    /// The start of the name a cache is made under before it is renamed into place: `making-<pid>-t<start>-<uuid>`.
    private static var makingPrefix: String {
        "making-"
    }

    /// What precedes the maker's start time in that name: the `t` of `t<start>`, which no earlier version's name has there — its next field is a UUID's, hexadecimal in capitals.
    private static var startTag: String {
        "t"
    }

    /// The start of the name whatever reclamation removes is renamed to first: `reclaimed-<uuid>`.
    private static var discardedPrefix: String {
        "reclaimed-"
    }

    /// Makes the directory ready to open: there, marked with its store, and every sibling that no longer answers for a store reclaimed.
    ///
    /// A cache comes into being whole. One that is not there yet is made under a name of its own, `making-<pid>-t<start>-<uuid>`, which reclamation passes over while that process — that pid, started then — runs, marked there, and renamed into place; a marker rewritten later is replaced in one rename too. So no reclaimer ever finds a live store's cache without the file naming its store — which reads as a cache naming none, and goes — or with half of one. The closures passed in are a test's way into the instants a real race would have to hit: the first runs between the marking and the rename, the second between a directory being found there and its marking.
    ///
    /// A directory found there can go before it is marked — discarded by a reclaimer, or set aside by another process's open — and that is no failure of this store, which the engine would remember as one until the next build. So an attempt that leaves no directory behind is made once more.
    func prepare(whileMaking: () throws -> Void = {}, beforeMarking: () throws -> Void = {}) throws {
        let marker = Data("\(storePath)\n".utf8)
        do {
            try markOrMake(marker, whileMaking: whileMaking, beforeMarking: beforeMarking)
        } catch where !FileManager.default.fileExists(atPath: directory.path) {
            try markOrMake(marker, whileMaking: whileMaking, beforeMarking: beforeMarking)
        }
        reclaimSiblings()
    }

    /// Whether the store is still the one this cache was named for: at its path, with the identity it had then.
    var stillNamesItsStore: Bool {
        let cacheRoot = directory.deletingLastPathComponent().deletingLastPathComponent()
        return SemanticCache(store: URL(fileURLWithPath: storePath), in: cacheRoot)?.directory.lastPathComponent == directory.lastPathComponent
    }

    /// Discards this cache while an open still holds it — the open that read another store in place of the one this cache was named for.
    ///
    /// Abandoning it is not enough: the store it was named for can come back to its path, moved away and back with its inode and creation time, and then this key is that store's again, and the cache would answer for it from the other store's units. So it is renamed aside before the open lets go — IndexStoreDB's close moves its copy back to `saved` by path, and finds nothing to move back under this key — and removed there. Another process holding a copy loses it the same way, which costs a cold import.
    ///
    /// Should that rename fail — a directory the caches sit in that cannot be written, or an immutable flag — this process's own copy goes in its place: each `v<N>/p<pid>-…` renamed to a `-dead` name and removed, so the close again finds nothing to move back. A removal cut short leaves a name IndexStoreDB sweeps on its next open of the cache, and that no reclaimer counts as held.
    func setAside() {
        guard !Self.discard(directory, into: directory.deletingLastPathComponent()) else { return }
        let manager = FileManager.default
        for version in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let names = (try? manager.contentsOfDirectory(atPath: version.path)) ?? []
            for name in names where !name.hasSuffix("-dead") && Self.processID(inCopyNamed: name) == getpid() {
                let dead = version.appendingPathComponent("\(name)-dead", isDirectory: true)
                guard (try? manager.moveItem(at: version.appendingPathComponent(name), to: dead)) != nil else { continue }
                try? manager.removeItem(at: dead)
            }
        }
    }

    /// Marks the directory when it is there, and makes it when it is not.
    private func markOrMake(_ marker: Data, whileMaking: () throws -> Void, beforeMarking: () throws -> Void) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try beforeMarking()
            try mark(with: marker)
        } else {
            try make(marker: marker, whileMaking: whileMaking, beforeMarking: beforeMarking)
        }
    }

    /// Writes the file naming the store in one rename, so no reclaimer finds half of one.
    private func mark(with marker: Data) throws {
        try marker.write(to: directory.appendingPathComponent(Self.markerName), options: .atomic)
    }

    /// Makes the directory under a name reclamation passes over, marks it, and renames it into place — or, when the rename loses, marks the directory already there rather than take it as made.
    ///
    /// Another process may have made it whole, or an open may have made it bare: IndexStoreDB makes `<key>/v<N>` for itself as it opens, so an open of a key another process has just reclaimed makes that directory again with no marker in it. Taken as made, it was a cache naming no store, and the next reclaimer's to remove from under the open that took it.
    private func make(marker: Data, whileMaking: () throws -> Void, beforeMarking: () throws -> Void) throws {
        let manager = FileManager.default
        let started = KernelProcess.startMicroseconds(of: getpid()).map { "\(Self.startTag)\($0)-" } ?? ""
        let making = directory.deletingLastPathComponent()
            .appendingPathComponent("\(Self.makingPrefix)\(getpid())-\(started)\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: making, withIntermediateDirectories: true)
        // Nothing to remove once the rename has moved it; here for a marking or a rename that failed.
        defer { try? manager.removeItem(at: making) }
        try marker.write(to: making.appendingPathComponent(Self.markerName))
        try whileMaking()
        do {
            try manager.moveItem(at: making, to: directory)
        } catch {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw error }
            try beforeMarking()
            try mark(with: marker)
        }
    }

    /// Removes each other cache whose store is gone, has another identity now, or was never named, unless a running process holds it, and empties the flat `.sift/isdb/v<N>` earlier versions kept, which no store's key ever opens.
    ///
    /// Bounded by the stores that exist: a store's cache is kept for as long as the store is there, so switching back to it finds it warm rather than re-importing a store that can take minutes. Best effort, because a cache left behind costs disk and never an answer: no key reaches it.
    ///
    /// A cache being made is passed over while its maker runs, and one a maker left half-made when it died goes like any cache naming no store, even once another process has its pid (``isBeingMade(named:)``). Whatever goes is renamed aside first and removed under that name, so nothing is ever half-removed under a name an open reaches.
    private func reclaimSiblings() {
        let root = directory.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let cacheRoot = root.deletingLastPathComponent()
        for entry in entries where entry.lastPathComponent != directory.lastPathComponent {
            let name = entry.lastPathComponent
            if Self.isBeingMade(named: name) {
                continue
            }
            if Self.isFlatCache(named: name) {
                Self.empty(flat: entry, into: root)
            } else if !Self.isHeldByARunningProcess(entry), !Self.answersForItsStore(entry, in: cacheRoot) {
                Self.discard(entry, into: root)
            }
        }
    }

    /// Whether `cache` is the one its marker's store gets now: that store still there, with the identity it had when this cache was named for it.
    private static func answersForItsStore(_ cache: URL, in cacheRoot: URL) -> Bool {
        guard let named = try? String(contentsOf: cache.appendingPathComponent(markerName), encoding: .utf8) else { return false }
        let path = named.trimmingCharacters(in: .newlines)
        // A marker naming no absolute path names no store: read as a file URL, an empty one is the current directory.
        guard path.hasPrefix("/"), let current = SemanticCache(store: URL(fileURLWithPath: path), in: cacheRoot) else { return false }
        return current.directory.lastPathComponent == cache.lastPathComponent
    }

    /// Empties the flat cache `flat` of every database no running process has open, and leaves the directory itself.
    ///
    /// A process of an earlier version opens it with no lock: it makes the directory if it is missing, then a copy of its own inside it, then renames `saved` into that copy. Removing the directory between its first two steps would fail that open, and an earlier version's server remembers a failure until the next build or until it restarts (a CLI run remembers nothing past itself). Moving a database out is one rename, and that sequence cannot be caught halfway by one: an open that renamed `saved` first leaves nothing here to move, one that comes to it after finds none and starts a fresh import, and a copy made in the meantime is a running process's and stays. What is left is an empty directory.
    private static func empty(flat: URL, into root: URL) {
        let databases = (try? FileManager.default.contentsOfDirectory(at: flat, includingPropertiesForKeys: nil)) ?? []
        for database in databases where !isLiveCopy(database.lastPathComponent) {
            discard(database, into: root)
        }
    }

    /// Renames `item` to a name no open computes, `reclaimed-<uuid>` beside the caches, and removes it there — or, should that removal be cut short, at a later open, where it names no store.
    ///
    /// Returns whether the rename happened: an item it could not move is left where it was.
    @discardableResult
    private static func discard(_ item: URL, into root: URL) -> Bool {
        let discarded = root.appendingPathComponent("\(discardedPrefix)\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.moveItem(at: item, to: discarded)) != nil else { return false }
        try? FileManager.default.removeItem(at: discarded)
        return true
    }

    /// Whether `name` is the flat cache earlier versions kept at `.sift/isdb/v<N>` — never a store's key, which is hexadecimal.
    private static func isFlatCache(named name: String) -> Bool {
        name.hasPrefix("v") && Int(name.dropFirst()) != nil
    }

    /// Whether `name` is a `making-<pid>-t<start>-<uuid>` directory whose maker still runs: that pid, started when the name says.
    ///
    /// The start time is what a process that takes a dead maker's pid cannot share, so what that maker left half-made is reclaimed rather than kept until the process holding its pid exits. A name with no start time, as an earlier version writes, is judged by its pid alone, and so is a maker whose start time cannot be read: taken for dead, a live one would lose its directory, then fail its rename into place with nothing to fall back on. Its start times come from the reader passed in: the kernel's, or a test's stand-in for a read that fails.
    static func isBeingMade(named name: String, startOf: (pid_t) -> UInt64? = KernelProcess.startMicroseconds(of:)) -> Bool {
        guard name.hasPrefix(makingPrefix) else { return false }
        let fields = name.dropFirst(makingPrefix.count).split(separator: "-", maxSplits: 2)
        guard let pid = fields.first.flatMap({ pid_t($0) }) else { return false }
        guard fields.count > 1, fields[1].hasPrefix(startTag), let started = UInt64(fields[1].dropFirst(startTag.count)) else {
            return isRunning(pid)
        }
        guard let current = startOf(pid) else { return isRunning(pid) }
        return current == started
    }

    /// Whether a running process has `cache` open.
    ///
    /// IndexStoreDB moves the database it opens out of `saved` into a private `p<pid>-…` directory beside it, and back on close, the last to close winning. Looked for one and two levels down, where each layout keeps it: `<key>/v<N>/p<pid>-…` in a store's own cache, `v<N>/p<pid>-…` in the flat one (``isLiveCopy(_:)``).
    static func isHeldByARunningProcess(_ cache: URL) -> Bool {
        let manager = FileManager.default
        let levels = [cache] + ((try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [])
        for level in levels {
            guard let names = try? manager.contentsOfDirectory(atPath: level.path) else { continue }
            if names.contains(where: isLiveCopy) {
                return true
            }
        }
        return false
    }

    /// Whether `name` is IndexStoreDB's copy of a database a running process has open, `p<pid>-<suffix>`.
    ///
    /// A copy whose process has died holds nothing, and IndexStoreDB's own sweep discards it too. Neither does a name ending `-dead`, whatever pid it carries: IndexStoreDB moves a database it displaced there on close — `p<pid>-…-saved-dead` when another process had written `saved` back first — and its sweep removes every such name. Counted as held, one kept a cache whose store was gone for as long as the process that closed it ran on, and nothing opens such a cache again to sweep it. A pid reused by an unrelated process still reads as running, which keeps a dead copy's cache on disk until that process exits: disk, never an answer.
    private static func isLiveCopy(_ name: String) -> Bool {
        guard !name.hasSuffix("-dead"), let pid = processID(inCopyNamed: name) else { return false }
        return isRunning(pid)
    }

    /// The pid in IndexStoreDB's `p<pid>-<suffix>` name for a database a process has open, or `nil` for any other name.
    private static func processID(inCopyNamed name: String) -> pid_t? {
        guard name.hasPrefix("p"), let dash = name.firstIndex(of: "-"),
              let pid = pid_t(name[name.index(after: name.startIndex) ..< dash]), pid > 0 else { return nil }
        return pid
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
