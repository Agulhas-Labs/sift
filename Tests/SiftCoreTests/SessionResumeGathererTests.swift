//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers ``SessionResumeGatherer``'s reads: the ledger's root-exact-match and 24-hour window, the declaration comparison's file cap, and that one gatherer's failure never costs the others their facts.
///
/// The staleness tests each start from `quietRepository` — a history, and reflogs, dated an hour before the run they record — and then make exactly one change, so each fails if the one signal it is about stops being read.
@Suite(.temporaryDirectories)
struct SessionResumeGathererTests {
    @Test
    func aLedgerRecordForAnotherRootIsIgnored() throws {
        let repo = try TestSources.makeTempRepo()
        let ledger = try Self.ledger([
            Self.record(root: "/somewhere/else", kind: "swift test", timestamp: Date()),
        ])

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger)

        #expect(facts.lastRun == nil)
    }

    @Test
    func aRecordOlderThan24HoursIsIgnored() throws {
        let repo = try TestSources.makeTempRepo()
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: Date().addingTimeInterval(-25 * 3600)),
        ])

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger)

        #expect(facts.lastRun == nil)
    }

    @Test
    func aMatchingFreshRecordIsRead() throws {
        let repo = try TestSources.makeTempRepo()
        let ledger = try Self.ledger([
            Self.record(
                root: repo.path, kind: "swift test", timestamp: Date().addingTimeInterval(-300),
                exit: 1, failed: ["GizmoTests"], failedTotal: 1
            ),
        ])

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger)
        let lastRun = try #require(facts.lastRun)

        #expect(lastRun.kind == "swift test")
        #expect(lastRun.exitCode == 1)
        #expect(lastRun.failedTests == ["GizmoTests"])
    }

    /// A linked worktree is a different root from the checkout it was cut from, so a record filed under one must never answer for the other.
    @Test
    func aRecordForTheCheckoutDoesNotAnswerForItsWorktree() throws {
        let repo = try TestSources.makeTempRepo()
        let worktree = try TestSources.makeWorktree(of: repo, named: "agent-1")
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: Date()),
        ])

        let facts = SessionResumeGatherer.gather(repositoryRoot: worktree, runLedgerURL: ledger)

        #expect(facts.lastRun == nil)
    }

    /// Only the ledger's end is read, and a tail that starts mid-line still reads every whole line after it.
    @Test
    func onlyTheLedgersTailIsRead() throws {
        let repo = try TestSources.makeTempRepo()
        let now = Date()
        let others = (0 ..< 20).map { _ in Self.record(root: "/somewhere/else", kind: "swift build", timestamp: now) }
        let mine = Self.record(root: repo.path, kind: "swift test", timestamp: now)

        let mineFirst = try Self.ledger([mine] + others)
        #expect(SessionResumeGatherer.lastRun(repositoryRoot: repo, runLedgerURL: mineFirst, now: now, tailBytes: 400) == nil)
        #expect(SessionResumeGatherer.lastRun(repositoryRoot: repo, runLedgerURL: mineFirst, now: now)?.kind == "swift test")

        let mineLast = try Self.ledger(others + [mine])
        #expect(SessionResumeGatherer.lastRun(repositoryRoot: repo, runLedgerURL: mineLast, now: now, tailBytes: 400)?.kind == "swift test")
    }

    // MARK: - Staleness: one signal per test

    /// The control: with nothing in the tree newer than the run's start, its verdict reads as current.
    @Test
    func nothingChangedSinceTheRunReadsAsCurrent() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("swift test — passed"))
        #expect(block.contains("tree has changed since") == false)
    }

    @Test
    func aCommitAfterTheRunMakesTheTreeReadAsChangedSince() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift build", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.write("struct Scratch {}", to: "Sources/Scratch.swift", in: repo)
        try TestSources.runGit(["add", "-A"], in: repo)
        try TestSources.runGit(["commit", "-m", "after the run"], in: repo, dated: now.addingTimeInterval(-300))
        // Only the commit's own date is later than the run: the reflog it wrote is put back.
        try Self.backdateReflogs(of: repo, to: seeded)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    @Test
    func anUncommittedEditAfterTheRunAlsoReadsAsChangedSince() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift build", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.write("struct Scratch {}", to: "Sources/Scratch.swift", in: repo)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// A detached `HEAD` — a paused rebase, a bisect — has no branch name, and neither the edit's date nor the declarations may depend on one.
    @Test
    func aDetachedHeadStillDatesAnEditAndNamesItsDeclarations() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        try TestSources.runGit(["checkout", "--detach"], in: repo)
        try Self.backdateReflogs(of: repo, to: seeded)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.write("struct Scratch {}", to: "Sources/Scratch.swift", in: repo)

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger, now: now)
        let block = try #require(SessionResumeBlock.render(facts, now: now))

        #expect(block.contains("tree has changed since"))
        #expect(block.contains("detached HEAD at "))
        #expect(facts.declarations == SessionResumeFacts.ChangedDeclarations(detail: .names(["+Scratch"], moreCount: 0)))
    }

    @Test
    func noDefaultBranchStillDatesAnEditMadeAfterTheRun() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        try TestSources.runGit(["branch", "-m", "main", "trunk"], in: repo)
        try Self.backdateReflogs(of: repo, to: seeded)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.write("struct Scratch {}", to: "Sources/Scratch.swift", in: repo)

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger, now: now)
        let block = try #require(SessionResumeBlock.render(facts, now: now))

        #expect(facts.branch?.defaultBranchName == nil)
        #expect(block.contains("tree has changed since"))
    }

    /// A checkout moves `HEAD` to a commit that can be older than the run — nothing dated after it except the reflog entry the checkout wrote.
    @Test
    func switchingBranchesAfterTheRunReadsAsChangedSince() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        try TestSources.runGit(["branch", "feat"], in: repo)
        try Self.backdateReflogs(of: repo, to: seeded)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.runGit(["checkout", "feat"], in: repo)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// A deleted file has no modification time to date it by, so its deletion can never be shown to predate the run.
    @Test
    func aDirtyDeletionReadsAsChangedSince() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try FileManager.default.removeItem(at: repo.appendingPathComponent("README.md"))

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// `rename(2)` keeps a file's modification time and `git mv` writes no reflog, so a rename after the run moves nothing datable — the rename itself is what has to count.
    @Test
    func aRenameAfterTheRunReadsAsChangedSince() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.runGit(["mv", "README.md", "READ-ME.md"], in: repo)
        try Self.setModificationDate(seeded, of: "READ-ME.md", in: repo)
        try Self.backdateReflogs(of: repo, to: seeded)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// A `HEAD` with no reflog has lost the one record of when it last moved, so nothing proves the move predates the run.
    @Test
    func aMissingHeadReflogReadsAsChangedSince() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/logs/HEAD"))

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// A stash takes the tested edit out of the tree and leaves nothing dirty behind — only the stash's own reflog says so.
    @Test
    func stashingAfterTheRunReadsAsChangedSince() throws {
        let now = Date()
        let seeded = now.addingTimeInterval(-3600)
        let repo = try Self.quietRepository(seededAt: seeded)
        try TestSources.write("edited\n", to: "README.md", in: repo)
        try Self.setModificationDate(seeded, of: "README.md", in: repo)
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try TestSources.runGit(["stash"], in: repo)
        try Self.backdate(["logs/HEAD"], of: repo, to: seeded)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    /// An edit made while a long test phase was still running is earlier than the record's `ts` but later than the run's start, and the run never measured it.
    @Test
    func anEditMadeWhileTheRunWasGoingReadsAsChangedSince() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-300), milliseconds: 600_000),
        ])
        try TestSources.write("struct Scratch {}", to: "Sources/Scratch.swift", in: repo)
        try Self.setModificationDate(now.addingTimeInterval(-600), of: "Sources/Scratch.swift", in: repo)

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
    }

    // MARK: - Writes nothing

    /// `git status` refreshes the index's stat cache and writes it back whenever it can take the lock; the resumption gather runs with optional locks off, so a touched file leaves `.git/index` exactly as it was.
    @Test
    func theGatherLeavesTheIndexUntouched() throws {
        let repo = try Self.quietRepository(seededAt: Date().addingTimeInterval(-3600))
        try Self.setModificationDate(Date().addingTimeInterval(-120), of: "README.md", in: repo)
        let index = repo.appendingPathComponent(".git/index")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let bytesBefore = try Data(contentsOf: index)

        _ = try SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: Self.emptyLedger())

        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        #expect(after == before)
        #expect(try Data(contentsOf: index) == bytesBefore)
    }

    // MARK: - Declarations

    @Test
    func aCommittedPureRenameChangesNoDeclarations() throws {
        let repo = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {}\n", to: "Sources/Gizmo.swift", in: repo)
        try TestSources.commitAll(in: repo, message: "gizmo")
        try TestSources.runGit(["checkout", "-b", "feat"], in: repo)
        try TestSources.runGit(["mv", "Sources/Gizmo.swift", "Sources/Gadget.swift"], in: repo)
        try TestSources.commitAll(in: repo, message: "rename")

        let facts = try SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: Self.emptyLedger())

        #expect(facts.declarations == nil)
    }

    @Test
    func anUncommittedPureRenameChangesNoDeclarations() throws {
        let repo = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {}\n", to: "Sources/Gizmo.swift", in: repo)
        try TestSources.commitAll(in: repo, message: "gizmo")
        try TestSources.runGit(["mv", "Sources/Gizmo.swift", "Sources/Gadget.swift"], in: repo)

        let facts = try SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: Self.emptyLedger())

        #expect(facts.declarations == nil)
    }

    @Test
    func theFileCapFallsBackToACountRatherThanTheDeclarations() throws {
        let repo = try TestSources.makeTempRepo()
        try TestSources.write("struct One {}", to: "Sources/One.swift", in: repo)
        try TestSources.write("struct Two {}", to: "Sources/Two.swift", in: repo)
        try TestSources.write("struct Three {}", to: "Sources/Three.swift", in: repo)

        let facts = try SessionResumeGatherer.gather(
            repositoryRoot: repo, runLedgerURL: Self.emptyLedger(), fileCap: 2
        )

        #expect(facts.declarations == SessionResumeFacts.ChangedDeclarations(detail: .fileCountFallback(3)))
    }

    @Test
    func exhaustingTheBudgetAlsoFallsBackToACount() throws {
        let repo = try TestSources.makeTempRepo()
        try TestSources.write("struct One {}", to: "Sources/One.swift", in: repo)

        let facts = try SessionResumeGatherer.gather(
            repositoryRoot: repo, runLedgerURL: Self.emptyLedger(), declarationParseBudget: 0
        )

        #expect(facts.declarations == SessionResumeFacts.ChangedDeclarations(detail: .fileCountFallback(1)))
    }

    /// One file too large to parse inside the budget is never started; the count stands in for the list, as it does when the budget runs out.
    @Test
    func aFileOverTheSizeCapFallsBackToACount() throws {
        let repo = try TestSources.makeTempRepo()
        try TestSources.write("struct One {}", to: "Sources/One.swift", in: repo)

        let facts = try SessionResumeGatherer.gather(
            repositoryRoot: repo, runLedgerURL: Self.emptyLedger(), fileSizeCap: 8
        )

        #expect(facts.declarations == SessionResumeFacts.ChangedDeclarations(detail: .fileCountFallback(1)))
    }

    @Test
    func moreThanTenChangedDeclarationsAreCountedPastTheCap() throws {
        let repo = try TestSources.makeTempRepo()
        let eleven = (1 ... 11).map { "struct S\($0) {}" }.joined(separator: "\n")
        try TestSources.write(eleven, to: "Sources/Many.swift", in: repo)

        let facts = try SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: Self.emptyLedger())
        guard case let .names(names, moreCount) = try #require(facts.declarations).detail else {
            Issue.record("expected a name list, got the fallback")
            return
        }

        #expect(names.count == 10)
        #expect(moreCount == 1)
    }

    // MARK: - Independence and the overall deadline

    /// A directory that is not a git repository at all fails every git-backed fact, but the ledger read shares none of git's machinery and still answers.
    @Test
    func aNonGitDirectoryStillReadsTheLedger() throws {
        let plain = try TestSources.makeTempDirectory()
        let ledger = try Self.ledger([Self.record(root: plain.path, kind: "swift test", timestamp: Date())])

        let facts = SessionResumeGatherer.gather(repositoryRoot: plain, runLedgerURL: ledger)

        #expect(facts.lastRun != nil)
        #expect(facts.branch == nil)
        #expect(facts.declarations == nil)
    }

    /// The reverse direction: an unreadable ledger costs only the run line, never the branch position.
    @Test
    func anUnreadableLedgerStillLeavesBranchFactsIntact() throws {
        let repo = try TestSources.makeTempRepo()
        let missingLedger = try TestSources.makeTempDirectory().appendingPathComponent("does-not-exist.jsonl")

        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: missingLedger)

        #expect(facts.lastRun == nil)
        #expect(facts.branch != nil)
    }

    /// Past its deadline the gather is given up on — the caller goes on without it — and within it, its answer comes back.
    @Test
    func theBoundGivesUpAtItsDeadline() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let stuck = SessionResumeGatherer.bounded(by: 0.05) {
            release.wait()
            return 1
        }
        let prompt = SessionResumeGatherer.bounded(by: 30) { 2 }

        #expect(stuck == nil)
        #expect(prompt == 2)
    }

    /// A dirty set git could not list (`dirtyFiles()` throws) is the one signal `recordTreeMovement` cannot date at all — nothing proves the unlisted changes predate the run, so the gather reads as stale without saying anything false about how many files are uncommitted.
    @Test
    func aDirtySetGitCouldNotListReadsAsChangedSince() throws {
        let now = Date()
        let repo = try Self.quietRepository(seededAt: now.addingTimeInterval(-3600))
        let ledger = try Self.ledger([
            Self.record(root: repo.path, kind: "swift test", timestamp: now.addingTimeInterval(-600)),
        ])
        try Data("not an index".utf8).write(to: repo.appendingPathComponent(".git/index"))

        #expect(throws: (any Error).self) {
            try GitContext(repoRoot: repo).dirtyFiles()
        }

        let block = try Self.block(repo, ledger, now: now)

        #expect(block.contains("tree has changed since"))
        #expect(!block.contains("uncommitted"))
    }
}

private extension SessionResumeGathererTests {
    static func record(
        root: String,
        kind: String,
        timestamp: Date,
        exit: Int = 0,
        failed: [String]? = nil,
        failedTotal: Int? = nil,
        milliseconds: Int? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: timestamp),
            "kind": kind,
            "exit": exit,
            "root": root,
        ]
        if let failed {
            entry["failed"] = failed
        }
        if let failedTotal {
            entry["failed_total"] = failedTotal
        }
        if let milliseconds {
            entry["ms"] = milliseconds
        }
        return entry
    }

    static func ledger(_ records: [[String: Any]]) throws -> URL {
        let url = try TestSources.makeTempDirectory().appendingPathComponent("run.jsonl")
        let lines = try records.map { record -> String in
            let data = try JSONSerialization.data(withJSONObject: record)
            return String(data: data, encoding: .utf8) ?? ""
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func emptyLedger() throws -> URL {
        try TestSources.makeTempDirectory().appendingPathComponent("run.jsonl")
    }

    static func block(_ repo: URL, _ ledger: URL, now: Date, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let facts = SessionResumeGatherer.gather(repositoryRoot: repo, runLedgerURL: ledger, now: now)
        return try #require(SessionResumeBlock.render(facts, now: now), sourceLocation: sourceLocation)
    }

    /// A repository on `main` whose seed commit is dated `date`, and whose reflogs are set back to it too — git writes a reflog at the real moment of each operation, whatever date the commit carries.
    static func quietRepository(seededAt date: Date) throws -> URL {
        let root = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-b", "main"], in: root)
        try TestSources.runGit(["config", "user.email", "test@example.com"], in: root)
        try TestSources.runGit(["config", "user.name", "Tester"], in: root)
        try TestSources.write("seed\n", to: "README.md", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "seed"], in: root, dated: date)
        let repo = root.resolvingSymlinksInPath()
        try backdateReflogs(of: repo, to: date)
        return repo
    }

    static func backdateReflogs(of repo: URL, to date: Date) throws {
        try backdate(["logs/HEAD", "logs/refs/stash"], of: repo, to: date)
    }

    static func backdate(_ names: [String], of repo: URL, to date: Date) throws {
        for name in names {
            let url = repo.appendingPathComponent(".git").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    static func setModificationDate(_ date: Date, of relativePath: String, in repo: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: repo.appendingPathComponent(relativePath).path)
    }
}
