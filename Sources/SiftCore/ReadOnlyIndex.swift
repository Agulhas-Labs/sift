//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads another repository's index without ever writing to it.
///
/// Strictly read-only by construction: the database file must already exist (a root that was recorded but never indexed is skipped, never indexed as a side effect of someone else's question), the connection is opened `SQLITE_OPEN_READONLY`, and a schema-version mismatch skips the root rather than triggering the drop-and-rebuild a normal `IndexStore` open would run — which, against a live index the caller was not asked to touch, would be vandalism.
///
/// One place knows this, because every caller of it is asking about a repository the current query is *not* about: root resolution probing siblings, and the day report reading every registered root in turn.
public struct ReadOnlyIndex {
    /// A connection to the current-schema index at `root`, or `nil` when there is nothing safe to read.
    static func open(atRoot root: String) -> SQLiteDatabase? {
        let databasePath = SiftPaths.cache(in: URL(filePath: root)).appendingPathComponent(SiftPaths.indexFileName).path
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = try? SQLiteDatabase(readOnlyPath: databasePath),
              isCurrent(database)
        else {
            return nil
        }
        return database
    }

    /// A connection to the current-schema index at `root` inside a read transaction it keeps open, or `nil` when there is nothing safe to read.
    ///
    /// Every later read through the connection sees the store as it stood when this returned, whatever another process does to it meanwhile: an unlinked file stays readable through the handle, a store replaced by rename stays the old one, and one dropped and rebuilt in place stays the snapshot this transaction began on, since the store keeps a write-ahead log and a reader's snapshot outlives any writer's commit. The version is checked again inside the transaction, so the snapshot held is one this build can read.
    static func held(atRoot root: String) -> SQLiteDatabase? {
        guard let database = open(atRoot: root),
              (try? database.execute(ReadOnlyIndexStatement.beginSnapshot.sql)) != nil,
              isCurrent(database)
        else {
            return nil
        }
        return database
    }

    /// Whether `database` is at the schema version this build reads.
    private static func isCurrent(_ database: SQLiteDatabase) -> Bool {
        guard let version = try? database.prepare(PragmaStatement.userVersionRead.sql), (try? version.step()) == true else {
            return false
        }
        return version.columnInt(0) == Int64(IndexSchema.version)
    }

    /// The schema version this build keeps an index at.
    public static var schemaVersion: Int {
        Int(IndexSchema.version)
    }

    /// The schema version the index at `root` was written at, whichever build wrote it, or `nil` where there is no index there to read.
    ///
    /// The one reader here that opens a store at any version, since the version is its question; it reads nothing else.
    public static func storedSchemaVersion(atRoot root: String) -> Int? {
        let databasePath = SiftPaths.cache(in: URL(filePath: root)).appendingPathComponent(SiftPaths.indexFileName).path
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = try? SQLiteDatabase(readOnlyPath: databasePath),
              let version = try? database.prepare(PragmaStatement.userVersionRead.sql),
              (try? version.step()) == true
        else {
            return nil
        }
        let stored = Int(version.columnInt(0))
        return stored == 0 ? nil : stored
    }

    /// The resolution fingerprint stored at `root`'s index, whichever build wrote it, or `nil` where there is none to read.
    public static func storedResolutionFingerprint(atRoot root: String) -> String? {
        let databasePath = SiftPaths.cache(in: URL(filePath: root)).appendingPathComponent(SiftPaths.indexFileName).path
        guard FileManager.default.fileExists(atPath: databasePath),
              let database = try? SQLiteDatabase(readOnlyPath: databasePath),
              let statement = try? database.prepare(StoreStatement.metaGet.sql)
        else {
            return nil
        }
        statement.bind(1, "resolution_fingerprint")
        guard (try? statement.step()) == true else {
            return nil
        }
        return statement.columnText(0)
    }

    /// The resolution fingerprint this build would stamp a fresh index of `root` with.
    public static func resolutionFingerprint(atRoot root: String) -> String {
        let url = URL(filePath: root)
        let config = (try? SiftConfig.load(repoRoot: url)) ?? SiftConfig()
        return ModuleResolver(repoRoot: url, config: config).fingerprint
    }

    /// What the index at `root` holds, or `nil` when it cannot be read.
    ///
    /// The guessed-module count is here because it is the one number that explains an otherwise puzzling report: on a build system whose manifests the resolver does not read, files answer about modules that do not exist, and every answer drawn from them is subtly wrong while looking fine.
    public static func snapshot(atRoot root: String) -> Snapshot? {
        guard let database = ReadOnlyIndex.open(atRoot: root),
              let statement = try? database.prepare(ReadOnlyIndexStatement.fileAndGuessedModuleCounts.sql),
              (try? statement.step()) == true
        else {
            return nil
        }
        return Snapshot(files: Int(statement.columnInt(0)), guessedModules: Int(statement.columnInt(1)))
    }

    /// Whether the syntactic index at `root` has completed at least one build — the same predicate `SiftEngine.ensureFresh()` uses to decide a full index is owed (0 files, or no `indexed_head` meta row).
    ///
    /// A store that merely opens at the current schema is not enough: an in-place answerer that overran its budget leaves exactly this — the file created, nothing indexed into it — and that store must count as no index at all, the same as a missing one, or nothing ever fills it.
    public static func hasUsableIndex(atRoot root: String) -> Bool {
        open(atRoot: root).map(isUsable) ?? false
    }

    /// Whether the index `database` holds has completed at least one build, by the predicate ``hasUsableIndex(atRoot:)`` names.
    static func isUsable(_ database: SQLiteDatabase) -> Bool {
        guard let filesStatement = try? database.prepare(ReadOnlyIndexStatement.fileCount.sql),
              (try? filesStatement.step()) == true
        else {
            return false
        }
        guard filesStatement.columnInt(0) > 0 else {
            return false
        }
        guard let headStatement = try? database.prepare(ReadOnlyIndexStatement.indexedHead.sql) else {
            return false
        }
        return (try? headStatement.step()) == true
    }

    /// Whether the repository at `root` has a build's index store for the semantic phase to read, found by the probes an engine makes (``IndexStoreDiscovery``) — the filesystem alone: nothing is opened, and several matching stores are not weighed against each other.
    public static func hasIndexStore(atRoot root: String) -> Bool {
        let url = URL(filePath: root)
        // A configuration that does not load stops an engine opening at all; probed with the defaults, the answer
        // is still whether a store is there to find.
        var discovery = IndexStoreDiscovery(repoRoot: url, config: (try? SiftConfig.load(repoRoot: url)) ?? SiftConfig())
        discovery.weighsCandidates = false
        return discovery.discover() != nil
    }
}

public extension ReadOnlyIndex {
    /// The shape of one repository's index, as a reader can see it.
    struct Snapshot: Sendable, Equatable {
        public let files: Int
        public let guessedModules: Int

        public init(files: Int, guessedModules: Int) {
            self.files = files
            self.guessedModules = guessedModules
        }
    }
}
