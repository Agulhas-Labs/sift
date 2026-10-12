//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// Orchestrates parsing into the store: full builds, incremental path sets, and the reconcile backstop.
struct Indexer {
    let repoRoot: URL
    let store: IndexStore
    let enumerator: FileEnumerator
    let resolver: ModuleResolver

    /// Parses and stores every listed file, purging rows that are no longer listed or no longer parseable — a full rebuild must never leave ghosts (Docs/Design.md §6.4) — and returns how many files it parsed.
    ///
    /// `storeBuiltAt` dates the build's index store — its newest unit, from discovery alone — or is `nil` with no store to date. It is asked only when the store has never kept a ledger, which is the one time the seed needs it.
    ///
    /// `resuming` takes up a build an earlier process abandoned (Docs/Design.md §6.9): the stored rows are brought under the current resolver first, once per resolver rather than once per attempt (``stampResolution(resuming:)``), and a stored row its file still matches (``reparseNeed(of:row:)``) is kept rather than parsed again. Without it every listed file is parsed. Either way each batch is stored as its parses land, and a cancelled task stops at the next batch boundary, so whatever a kill or a cancel interrupted is kept for the next attempt. Compacting is the caller's, once the build is marked done.
    @discardableResult
    func fullIndex(storeBuiltAt: () -> Date?, resuming: Bool = false) async throws -> Int {
        let paths = enumerator.swiftFiles()
        let listed = Set(paths)
        let now = Date()
        // Seeded before anything else drops a row: a drop writes the ledger, and a ledger present is what says
        // the seed already ran.
        try seedDeletionLedgerIfAbsent(listed: listed, storeBuiltAt: storeBuiltAt, at: now)
        let inventory = try store.fileInventory()
        let vanished = inventory.keys.filter { !listed.contains($0) }.sorted()
        try store.deleteFiles(paths: vanished, at: now, stillOnDisk: stillOnDisk)
        try stampResolution(resuming: resuming)
        let kept = resuming ? try await currentRows(among: paths, inventory: inventory) : []
        let toParse = paths.filter { !kept.contains($0) }
        let parsed = try await indexPaths(toParse, stoppingWhenCancelled: true)
        // A path that produced no ParsedFile is gone or unreadable (git still lists a tracked file deleted from the worktree) — its stale row must not survive the "rebuild from scratch". A kept row was not parsed, and is not one.
        let unparseable = Set(toParse).subtracting(parsed).sorted()
        try store.deleteFiles(paths: unparseable, at: now, stillOnDisk: stillOnDisk)
        return parsed.count
    }

    /// Marks a full build done at `head`, under the resolver it attributed modules by, then compacts the store (Docs/Design.md §6.5).
    ///
    /// Compacting comes after the head, not before: a process killed while compacting then leaves a finished index rather than a build owed again (Docs/Design.md §6.9).
    func markBuilt(atHead head: String) throws {
        try store.setMetaValue(head, forKey: "indexed_head")
        try store.setMetaValue(resolver.fingerprint, forKey: Self.resolutionStampKey)
        try store.compact()
    }

    /// Makes the resolution fingerprint, read as a stamp, true of every stored row before this build stores any (Docs/Design.md §6.9).
    ///
    /// Resuming, a stamp the current resolver does not match is made true by re-attributing every stored row and then stamping, so each row the build stores after it is attributed under the stamp too, and the next attempt under the same resolver finds it matching and skips the pass. A build from scratch rewrites rows without re-attributing the rest, so it never stamps before its head, and it blanks a stamp it does not match, which leaves no stamp vouching for rows it wrote under another resolver if it is stopped partway.
    private func stampResolution(resuming: Bool) throws {
        let fingerprint = resolver.fingerprint
        let stamp = try store.metaValue(Self.resolutionStampKey)
        guard stamp != fingerprint else { return }
        if resuming {
            _ = try store.reattributeModules { (resolver.module(for: $0), resolver.resolvedModule(for: $0) == nil) }
            try store.setMetaValue(fingerprint, forKey: Self.resolutionStampKey)
        } else if let stamp, !stamp.isEmpty {
            try store.setMetaValue("", forKey: Self.resolutionStampKey)
        }
    }

    /// The listed paths whose stored row still matches the file behind it, by the content test incremental indexing uses, the files read and hashed in parallel as the parse runs.
    ///
    /// Only the reading and hashing run in parallel: the change moments an unchanged file refreshes are written once every check is in, one after another, as ``reparseNeed(of:row:)`` writes them.
    private func currentRows(among paths: [String], inventory: [String: FileRow]) async throws -> Set<String> {
        let stored = paths.compactMap { path in inventory[path].map { (path: path, row: $0) } }
        guard !stored.isEmpty else { return [] }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let root = repoRoot
        var current: Set<String> = []
        var refreshed: [(path: String, changed: Double)] = []
        await withTaskGroup(of: (path: String, check: ContentCheck).self) { group in
            var iterator = stored.makeIterator()
            var inFlight = 0
            while inFlight < cores, let next = iterator.next() {
                group.addTask { (next.path, Self.contentCheck(of: next.path, row: next.row, under: root)) }
                inFlight += 1
            }
            for await (path, check) in group {
                if check.need == .unchanged {
                    current.insert(path)
                }
                if let changed = check.refreshedChange {
                    refreshed.append((path, changed))
                }
                if let next = iterator.next() {
                    group.addTask { (next.path, Self.contentCheck(of: next.path, row: next.row, under: root)) }
                }
            }
        }
        for (path, changed) in refreshed {
            try store.updateMtime(path: path, mtime: changed)
        }
        return current
    }

    /// Seeds the ``DeletionLedger`` of a store that has never kept one, once, before anything drops a row — `listed` being the tree's indexable files where the caller already has them.
    ///
    /// Two kinds of store arrive without a ledger. A fresh one — a `sift reset`, a schema-version rebuild, a wiped `.sift/`, a tree's first index — has no row to drop for a file already gone. One written by a binary from before the ledger may already have dropped a deleted file's rows without recording anything, and is never rebuilt for it, since the ledger lives in `meta` and needs no schema change. Either way the deletion is one `deleteFiles` alone can never see (Docs/Design.md §2), so every route into the index — a query's freshness check, a full index, a reconcile — asks this first, and every call after the first costs one `meta` read.
    func seedDeletionLedgerIfAbsent(listed: Set<String>? = nil, storeBuiltAt: () -> Date?, at instant: Date = Date()) throws {
        guard try store.lacksDeletionLedger else { return }
        let listed = listed ?? Set(enumerator.swiftFiles())
        try store.seedDeletionLedgerIfAbsent(missingPaths: deletionSeeds(listed: listed, storeBuiltAt: storeBuiltAt()), at: instant)
    }

    /// The deletions a store with no ledger can learn of with no rows of its own to drop for them.
    ///
    /// Three sources, because git forgets a deletion in stages. A plain delete leaves the path tracked but missing; `git rm`, or a delete staged with the rest of a change, takes it out of what git tracks, so only the staged diff still names it; and once committed, only history does — searched from the build's own date, since a build made after a deletion compiled a tree without the file. With no store to date there is no build for a deletion to postdate, and that third source is skipped. Each is kept only while the file is still missing and the index would cover it, the same rules a drop is recorded under. What none of them reaches is stated in Docs/Design.md §2.
    private func deletionSeeds(listed: Set<String>, storeBuiltAt: Date?) throws -> [String] {
        let git = GitContext(repoRoot: repoRoot)
        var seeds = listed.filter { !stillOnDisk($0) }
        try seeds.formUnion(git.stagedSwiftDeletions())
        if let storeBuiltAt {
            try seeds.formUnion(git.swiftFilesDeletedInCommits(since: storeBuiltAt))
        }
        return seeds.filter { enumerator.isIndexable(relativePath: $0) && !stillOnDisk($0) }.sorted()
    }

    /// Whether a repo-relative path still has a file behind it — the test a drop must pass before the ``DeletionLedger`` remembers it as a deletion rather than a row dropped for some other reason.
    ///
    /// Every caller of ``IndexStore/deleteFiles(paths:at:stillOnDisk:)`` passes this one.
    func stillOnDisk(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(path).path)
    }

    /// Parses and replaces the given repo-relative paths (parallel parse, delete-then-insert a batch at a time as the parses land); returns the paths that actually parsed.
    ///
    /// Storing as it goes, rather than once every file has parsed, is what lets a process killed partway keep what it parsed. Asked to stop when cancelled, it ends the work at the first batch boundary after the task is cancelled, throwing with every batch before it stored; only a full build asks for it, since only a full build marks nothing done until it ends.
    @discardableResult
    func indexPaths(_ paths: [String], stoppingWhenCancelled: Bool = false) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var stored: Set<String> = []
        var batch: [ParsedFile] = []
        batch.reserveCapacity(Self.batchSize)
        try await withThrowingTaskGroup(of: ParsedFile?.self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask { Self.parse(path, under: rootPath) }
                inFlight += 1
            }
            for try await parsed in group {
                if let parsed {
                    batch.append(parsed)
                }
                if let path = iterator.next() {
                    group.addTask { Self.parse(path, under: rootPath) }
                }
                guard batch.count >= Self.batchSize else { continue }
                try write(batch, into: &stored)
                batch.removeAll(keepingCapacity: true)
                if stoppingWhenCancelled {
                    try Task.checkCancellation()
                }
            }
        }
        try write(batch, into: &stored)
        return stored
    }

    /// Writes one batch of parses, one transaction, and notes their paths in `stored`.
    private func write(_ batch: [ParsedFile], into stored: inout Set<String>) throws {
        guard !batch.isEmpty else { return }
        try store.replaceFiles(batch) { (resolver.module(for: $0), resolver.resolvedModule(for: $0) == nil) }
        stored.formUnion(batch.map(\.path))
    }

    /// Diffs the git listing against the stored inventory and converges the index — the only mechanism guaranteed to catch what every other path missed (Docs/Design.md §6.4).
    @discardableResult
    func reconcile() async throws -> (removed: Int, reindexed: Int) {
        let listed = Set(enumerator.swiftFiles())
        let inventory = try store.fileInventory()

        var vanished = Set(inventory.keys.filter { !listed.contains($0) })
        var stale: [String] = []
        for path in listed {
            // Missing is listed by git but absent from the worktree: a tracked file deleted out-of-band.
            switch try reparseNeed(of: path, row: inventory[path]) {
            case .missing: vanished.insert(path)
            case .reparse: stale.append(path)
            case .unchanged: break
            }
        }
        try store.deleteFiles(paths: vanished.sorted(), stillOnDisk: stillOnDisk)
        let parsed = try await indexPaths(stale.sorted())
        let leftover = Set(stale).subtracting(parsed)
        try store.deleteFiles(paths: leftover.sorted(), stillOnDisk: stillOnDisk)
        if !vanished.isEmpty || !leftover.isEmpty {
            try store.compact()
        }
        return (vanished.count + leftover.count, parsed.count)
    }

    /// Whether a path needs a parse against its stored `row`, settled by content rather than by its stat (Docs/Design.md §2).
    ///
    /// No row or a differing size says yes, and an equal size is hashed whatever the mtime says, since `touch -r`, `cp -p` and a same-length rewrite inside one mtime tick all keep both. An equal hash under a new change moment refreshes the stored one, read the way a parse records it (``FileChangeStat``), so a standing dirty file keeps the moment its edit gave it rather than falling back to a restored mtime.
    func reparseNeed(of path: String, row: FileRow?) throws -> ReparseNeed {
        let check = Self.contentCheck(of: path, row: row, under: repoRoot)
        if let changed = check.refreshedChange {
            try store.updateMtime(path: path, mtime: changed)
        }
        return check.need
    }

    /// The content test of ``reparseNeed(of:row:)`` with nothing written: it reads the file and touches no store, so many can run at once.
    private static func contentCheck(of path: String, row: FileRow?, under root: URL) -> ContentCheck {
        let url = root.appendingPathComponent(path)
        guard let stat = FileChangeStat.of(path: url.path) else { return ContentCheck(need: .missing) }
        guard let row, stat.size == row.size else { return ContentCheck(need: .reparse) }
        guard let data = try? Data(contentsOf: url) else { return ContentCheck(need: .missing) }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == row.contentHash else { return ContentCheck(need: .reparse) }
        let refreshed = Swift.abs(stat.changed - row.mtime) >= 0.0001 ? stat.changed : nil
        return ContentCheck(need: .unchanged, refreshedChange: refreshed)
    }

    /// How many parses are stored in one transaction: the unit a kill can lose.
    static let batchSize = 100

    /// The meta key whose fingerprint says which resolver every stored row is attributed under.
    static var resolutionStampKey: String {
        "resolution_fingerprint"
    }

    private static func parse(_ path: String, under rootPath: String) -> ParsedFile? {
        FileParser.parse(absoluteURL: URL(fileURLWithPath: rootPath + "/" + path), repoRelativePath: path)
    }
}

extension Indexer {
    /// The three outcomes of checking a path against its stored row.
    enum ReparseNeed {
        case reparse
        case unchanged
        case missing
    }

    /// What the content test found for one path, and the change moment its row is to be refreshed to where the file is unchanged under a new one.
    struct ContentCheck {
        let need: ReparseNeed
        var refreshedChange: Double?
    }
}
