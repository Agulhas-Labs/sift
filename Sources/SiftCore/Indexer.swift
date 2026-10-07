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

    /// Parses and stores every listed file, purging rows that are no longer listed or no longer parseable — a full rebuild must never leave ghosts (Docs/Design.md §6.4).
    ///
    /// `storeBuiltAt` dates the build's index store — its newest unit, from discovery alone — or is `nil` with no store to date. It is asked only when the store has never kept a ledger, which is the one time the seed needs it.
    @discardableResult
    func fullIndex(storeBuiltAt: () -> Date?) async throws -> Int {
        let paths = enumerator.swiftFiles()
        let listed = Set(paths)
        let now = Date()
        // Seeded before anything else drops a row: a drop writes the ledger, and a ledger present is what says
        // the seed already ran.
        try seedDeletionLedgerIfAbsent(listed: listed, storeBuiltAt: storeBuiltAt, at: now)
        let vanished = try store.fileInventory().keys.filter { !listed.contains($0) }.sorted()
        try store.deleteFiles(paths: vanished, at: now, stillOnDisk: stillOnDisk)
        let parsed = try await indexPaths(paths)
        // A listed path that produced no ParsedFile is gone or unreadable (git still lists a tracked file deleted from the worktree) — its stale row must not survive the "rebuild from scratch".
        let unparseable = listed.subtracting(parsed).sorted()
        try store.deleteFiles(paths: unparseable, at: now, stillOnDisk: stillOnDisk)
        try store.compact()
        return parsed.count
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

    /// Parses and replaces the given repo-relative paths (parallel parse, batched delete-then-insert); returns the paths that actually parsed.
    @discardableResult
    func indexPaths(_ paths: [String]) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let parsed = await Self.parseMany(paths: paths, repoRoot: repoRoot)
        try store.replaceFiles(parsed) { (resolver.module(for: $0), resolver.resolvedModule(for: $0) == nil) }
        return Set(parsed.map(\.path))
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
        let url = repoRoot.appendingPathComponent(path)
        guard let stat = FileChangeStat.of(path: url.path) else { return .missing }
        guard let row, stat.size == row.size else { return .reparse }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == row.contentHash else { return .reparse }
        if Swift.abs(stat.changed - row.mtime) >= 0.0001 {
            try store.updateMtime(path: path, mtime: stat.changed)
        }
        return .unchanged
    }

    private static func parseMany(paths: [String], repoRoot: URL) async -> [ParsedFile] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var results: [ParsedFile] = []
        results.reserveCapacity(paths.count)
        await withTaskGroup(of: ParsedFile?.self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask {
                    FileParser.parse(absoluteURL: URL(fileURLWithPath: rootPath + "/" + path), repoRelativePath: path)
                }
                inFlight += 1
            }
            for await parsed in group {
                if let parsed {
                    results.append(parsed)
                }
                if let path = iterator.next() {
                    group.addTask {
                        FileParser.parse(absoluteURL: URL(fileURLWithPath: rootPath + "/" + path), repoRelativePath: path)
                    }
                }
            }
        }
        return results
    }
}

extension Indexer {
    /// The three outcomes of checking a path against its stored row.
    enum ReparseNeed {
        case reparse
        case unchanged
        case missing
    }
}
