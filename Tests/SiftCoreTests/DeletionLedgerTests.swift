//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one record of a deleted file that outlives its rows — what `status` counts deletions from without opening the index store.
@Suite(.temporaryDirectories)
struct DeletionLedgerTests {
    /// Only a path that had rows is a deletion: `deleteFiles` is also handed paths the index never held, and recording those would count files that were never here.
    @Test
    func onlyAPathThatHadRowsIsRecorded_AtTheMomentItWasDropped() throws {
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed("struct Widget {}\n", path: "Sources/App/Widget.swift")]) { _ in ("App", false) }

        try store.deleteFiles(paths: ["Sources/App/Widget.swift", "Sources/App/Never.swift"], at: Date(timeIntervalSince1970: 500))

        #expect(try store.deletionLedger().entries == ["Sources/App/Widget.swift": 500])
        #expect(try store.deletionLedger().paths(droppedAfter: 499) == ["Sources/App/Widget.swift"])
        #expect(try store.deletionLedger().paths(droppedAfter: 500).isEmpty)
    }

    /// Bounded, and by recency: a tree that loses more distinct files than the ledger holds keeps the latest drops, which are the ones a build anchor can still sit before.
    @Test
    func theLedgerKeepsTheMostRecentDropsUpToItsCapacity() {
        var ledger = DeletionLedger(metaValue: nil)
        ledger.record((0 ..< DeletionLedger.capacity).map { "Old\($0).swift" }, at: 1)
        ledger.record(["New.swift"], at: 2)

        #expect(ledger.entries.count == DeletionLedger.capacity)
        #expect(ledger.entries["New.swift"] == 2)
        #expect(DeletionLedger(metaValue: ledger.metaValue) == ledger)
    }

    // MARK: A drop is only a deletion if the file is actually gone

    /// A row dropped for a reason that leaves the file exactly where it was — narrowed away by a fresher `.sift.json`, newly gitignored — must not be recorded as a deletion: enough such non-deletions can otherwise evict a real one from the bounded ledger (Docs/Design.md §2).
    @Test
    func aDropWhoseFileIsStillOnDiskIsNotRecordedAsADeletion() throws {
        let store = try TestSources.makeStore()
        try store.replaceFiles([
            TestSources.parsed("struct Widget {}\n", path: "Sources/App/Widget.swift"),
            TestSources.parsed("struct Gone {}\n", path: "Sources/App/Gone.swift"),
        ]) { _ in ("App", false) }

        try store.deleteFiles(
            paths: ["Sources/App/Widget.swift", "Sources/App/Gone.swift"],
            at: Date(timeIntervalSince1970: 500),
            stillOnDisk: { $0 == "Sources/App/Widget.swift" }
        )

        #expect(try store.deletionLedger().entries == ["Sources/App/Gone.swift": 500])
    }

    /// A file git stops tracking and starts ignoring leaves the index and stays on disk.
    ///
    /// A query drops it — the commit's range diff lists it as deleted — and must not record it as a deletion.
    @Test
    func aQueryThatDropsAFileStillOnDiskDoesNotRecordIt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("struct Other {}\n", to: "Sources/App/Other.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        try TestSources.runGit(["rm", "-q", "--cached", "Sources/App/Other.swift"], in: root)
        try TestSources.write("Sources/App/Other.swift\n", to: ".gitignore", in: root)
        try TestSources.commitAll(in: root, message: "stop tracking")
        _ = try await engine.ensureFresh()

        // The drop happened, so the ledger was consulted on this path.
        #expect(try engine.store.fileInventory()["Sources/App/Other.swift"] == nil)
        #expect(try engine.store.deletionLedger().entries.isEmpty)
    }

    /// A full rebuild drops a file `.sift.json` has narrowed away, and `Indexer` must hand that drop the real check against the disk rather than record a file that never left.
    @Test
    func aFullIndexDropsANarrowedAwayFileWithoutRecordingIt() async throws {
        let engine = try await Self.engineWithAFileNarrowedAway()

        _ = try await engine.fullIndex()

        #expect(try engine.store.fileInventory()["Extras/Extra.swift"] == nil)
        #expect(try engine.store.deletionLedger().entries.isEmpty)
    }

    /// The reconcile sweep drops the same file by its own route, and must hand it the same check.
    @Test
    func aReconcileDropsANarrowedAwayFileWithoutRecordingIt() async throws {
        let engine = try await Self.engineWithAFileNarrowedAway()

        _ = try await engine.reconcile()

        #expect(try engine.store.fileInventory()["Extras/Extra.swift"] == nil)
        #expect(try engine.store.deletionLedger().entries.isEmpty)
    }

    /// An engine that indexed `Extras/Extra.swift` and has since read a `.sift.json` excluding it — the file still on disk, its rows not yet dropped.
    private static func engineWithAFileNarrowedAway(sourceLocation: SourceLocation = #_sourceLocation) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("struct Extra {}\n", to: "Extras/Extra.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("{\n  \"exclude\": [\"Extras/\"]\n}\n", to: ".sift.json", in: root)
        // Reads the config; a query drops nothing a config change narrows away, which is left to the two routes above.
        _ = try await engine.ensureFresh()
        try #require(try engine.store.fileInventory()["Extras/Extra.swift"] != nil, sourceLocation: sourceLocation)
        return engine
    }

    /// A copy leaves its source where it was, so it is not read as a rename of that source.
    ///
    /// Read as one, the source would be dropped and recorded as a deletion though it never left the disk. Git reports a copy only when its source changed in the same diff and copy detection is on, which is what the repository's own config sets up here.
    @Test
    func aCopyIsNotReadAsARenameOfItsSource() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.runGit(["config", "status.renames", "copies"], in: root)
        try TestSources.runGit(["config", "diff.renames", "copies"], in: root)
        let source = "struct Widget {\n    func one() {}\n    func two() {}\n    func three() {}\n}\n"
        try TestSources.write(source, to: "Sources/App/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try TestSources.write(source, to: "Sources/App/Copy.swift", in: root)
        try TestSources.write(source + "// edited\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        let git = GitContext(repoRoot: root)
        try #require(try TestSources.runGit(["status", "--porcelain"], in: root).contains("C  Sources/App/Widget.swift -> Sources/App/Copy.swift"))

        let dirty = try git.dirtySwiftFiles()
        try TestSources.runGit(["commit", "-q", "-m", "copy"], in: root)
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(try TestSources.runGit(["diff", "--name-status", base, head], in: root).contains("C100"))
        let range = try git.changedSwiftFiles(from: base, to: head)

        for changes in [dirty, range] {
            #expect(!changes.contains(where: Self.isRename))
            #expect(Set(changes.map(\.path)) == ["Sources/App/Widget.swift", "Sources/App/Copy.swift"])
        }
    }

    private static func isRename(_ change: GitContext.Change) -> Bool {
        guard case .renamed = change.kind else { return false }
        return true
    }

    // MARK: Seeding a store that has no ledger

    /// The one signal a store with no ledger has for a deletion it never held a row for.
    @Test
    func seedingAStoreWithNoLedgerRecordsTheMissingPaths() throws {
        let store = try TestSources.makeStore()

        try store.seedDeletionLedgerIfAbsent(missingPaths: ["Sources/App/Caller.swift"], at: Date(timeIntervalSince1970: 500))

        #expect(try store.deletionLedger().entries == ["Sources/App/Caller.swift": 500])
    }

    /// A no-op once the ledger holds anything at all — a second full index must never re-stamp a deletion a real drop already dated.
    @Test
    func seedingIsANoOpOnceTheLedgerAlreadyHoldsAnything() throws {
        let store = try TestSources.makeStore()
        try store.replaceFiles([TestSources.parsed("struct Widget {}\n", path: "Sources/App/Widget.swift")]) { _ in ("App", false) }
        try store.deleteFiles(paths: ["Sources/App/Widget.swift"], at: Date(timeIntervalSince1970: 100))

        try store.seedDeletionLedgerIfAbsent(missingPaths: ["Sources/App/Caller.swift"], at: Date(timeIntervalSince1970: 500))

        #expect(try store.deletionLedger().entries == ["Sources/App/Widget.swift": 100])
    }

    /// A seed with nothing to record still leaves a ledger behind, so it runs once per store: a later call finds a ledger and records nothing, even with a missing path to offer.
    @Test
    func aSeedWithNothingToRecordStillRunsOnlyOnce() throws {
        let store = try TestSources.makeStore()

        try store.seedDeletionLedgerIfAbsent(missingPaths: [], at: Date(timeIntervalSince1970: 500))
        try store.seedDeletionLedgerIfAbsent(missingPaths: ["Sources/App/Caller.swift"], at: Date(timeIntervalSince1970: 600))

        #expect(try !store.lacksDeletionLedger)
        #expect(try store.deletionLedger().entries.isEmpty)
    }

    /// A store written by a binary from before the ledger has none, and is never rebuilt for it — so the incremental query path seeds it, once, and a query after that seeds nothing.
    @Test
    func aQuerySeedsAStoreWrittenBeforeTheLedgerExactlyOnce() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("func greet() {}\n", to: "Sources/App/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/App/Caller.swift"))
        try Self.dropRowsAsABinaryFromBeforeTheLedger(paths: ["Sources/App/Caller.swift"], in: root)

        let upgraded = try SiftEngine(directory: root)
        _ = try await upgraded.ensureFresh()
        let seeded = try upgraded.store.deletionLedger().entries
        _ = try await upgraded.ensureFresh()

        #expect(Array(seeded.keys) == ["Sources/App/Caller.swift"])
        #expect(try upgraded.store.deletionLedger().entries == seeded)
    }

    /// What a binary from before the ledger leaves behind once it notices a deletion: the file's rows gone, and no ledger at all.
    static func dropRowsAsABinaryFromBeforeTheLedger(paths: [String], in root: URL) throws {
        let databasePath = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path
        try IndexStore(databasePath: databasePath).deleteFiles(paths: paths)
        try SQLiteDatabase(path: databasePath).execute("DELETE FROM meta WHERE key = '\(DeletionLedger.metaKey)'")
    }

    /// What that same kind of binary leaves behind once this store's ledger already exists: the rows gone, and the ledger exactly as it stood before — a binary that has never heard of it neither reads it nor writes it, so the drop it just made is not in there.
    static func dropRowsWithoutTouchingAnExistingLedger(paths: [String], in root: URL) throws {
        let databasePath = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path
        let store = try IndexStore(databasePath: databasePath)
        let before = try store.deletionLedger().metaValue
        try store.deleteFiles(paths: paths)
        try store.setMetaValue(before, forKey: DeletionLedger.metaKey)
    }

    // MARK: The reset scenario end to end

    /// `sift reset` (or a schema-version rebuild, or a `.sift/` a `git clean` wiped) loses the ledger along with everything else.
    ///
    /// The fresh store's first full index has no row to drop for `Caller.swift` — it never held one — so `deleteFiles` alone can never record the deletion; only the seed can.
    @Test
    func aFullIndexFromAnEmptyLedgerSeedsGitsTrackedButMissingFiles() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func greet() {}\n", to: "Sources/App/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/App/Caller.swift"))
        _ = try SiftEngine.reset(directory: root)

        let fresh = try SiftEngine(directory: root)
        _ = try await fresh.ensureFresh()

        #expect(try fresh.store.deletionLedger().entries.keys.contains("Sources/App/Caller.swift"))
    }

    /// With no build's index store there is no build for a committed deletion to postdate, so history is not searched — but a staged deletion needs no date, and is seeded all the same.
    @Test
    func withNoStoreAFullIndexSeedsAStagedDeletionAndLeavesHistoryAlone() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("func greet() {}\n", to: "Sources/App/Caller.swift", in: root)
        try TestSources.write("struct Gone {}\n", to: "Sources/App/Gone.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.runGit(["rm", "-q", "Sources/App/Gone.swift"], in: root)
        try TestSources.commitAll(in: root, message: "delete one")
        try TestSources.runGit(["rm", "-q", "Sources/App/Caller.swift"], in: root)

        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        #expect(try engine.store.deletionLedger().entries.keys.sorted() == ["Sources/App/Caller.swift"])
    }

    // MARK: What git still records of a deletion

    /// A rename is a deletion of its source to a store that compiled the source, staged or committed — and git's rename detection would report it as something else.
    @Test
    func aRenamedAwaySourceIsListedAsDeletedStagedAndCommitted() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("struct Gone {}\n", to: "Sources/App/Gone.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let git = GitContext(repoRoot: root)

        try TestSources.runGit(["mv", "Sources/App/Widget.swift", "Sources/App/Renamed.swift"], in: root)
        #expect(try git.stagedSwiftDeletions() == ["Sources/App/Widget.swift"])
        try TestSources.commitAll(in: root, message: "rename")
        try TestSources.runGit(["rm", "-q", "Sources/App/Gone.swift"], in: root)
        try TestSources.commitAll(in: root, message: "delete")

        #expect(try git.stagedSwiftDeletions().isEmpty)
        #expect(try git.swiftFilesDeletedInCommits(since: Date(timeIntervalSince1970: 1)).sorted() == [
            "Sources/App/Gone.swift", "Sources/App/Widget.swift",
        ])
        #expect(try git.swiftFilesDeletedInCommits(since: Date() + 3600).isEmpty)
    }

    /// A deletion merged in is named by the merge commit, dated when the merge was made — `git log` lists no files for a merge unless asked for its diff against the first parent, so without that the deletion is dated only by its own older commit.
    @Test
    func aDeletionMergedInIsListedByTheMergesOwnDate() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.write("struct Gone {}\n", to: "Sources/App/Gone.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let older = Date(timeIntervalSince1970: 1_000_000_000)
        try TestSources.runGit(["switch", "-q", "-c", "side"], in: root)
        try TestSources.runGit(["rm", "-q", "Sources/App/Gone.swift"], in: root)
        try TestSources.runGit(["commit", "-q", "-m", "delete"], in: root, dated: older)
        try TestSources.runGit(["switch", "-q", "-"], in: root)
        try TestSources.write("struct Widget {}\n// edited\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.runGit(["commit", "-q", "-am", "edit"], in: root, dated: older)
        try TestSources.runGit(["merge", "-q", "--no-ff", "-m", "merge", "side"], in: root)

        let deleted = try GitContext(repoRoot: root).swiftFilesDeletedInCommits(since: older + 3600)

        #expect(deleted == ["Sources/App/Gone.swift"])
    }

    /// A date in the first years after 1970 bounds the search at that moment: a deletion committed long before today is listed since the start of time and not since a second after it was made.
    @Test
    func aDateOfFewDigitsIsReadAsSecondsSince1970() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gone {}\n", to: "Sources/App/Gone.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let made = Date(timeIntervalSince1970: 50_000_000)
        try TestSources.runGit(["rm", "-q", "Sources/App/Gone.swift"], in: root)
        try TestSources.runGit(["commit", "-q", "-m", "delete"], in: root, dated: made)
        let git = GitContext(repoRoot: root)

        #expect(try git.swiftFilesDeletedInCommits(since: Date(timeIntervalSince1970: 1)) == ["Sources/App/Gone.swift"])
        #expect(try git.swiftFilesDeletedInCommits(since: made) == ["Sources/App/Gone.swift"])
        #expect(try git.swiftFilesDeletedInCommits(since: made + 1).isEmpty)
    }

    /// An unborn branch has no history to search, which is an empty answer rather than a failed full index.
    @Test
    func anUnbornBranchHasNoCommittedDeletions() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-q"], in: root)

        #expect(try GitContext(repoRoot: root).swiftFilesDeletedInCommits(since: Date(timeIntervalSince1970: 1)).isEmpty)
    }
}
