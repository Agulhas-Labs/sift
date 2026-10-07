//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers ``SessionResumeBlock``'s pure half: which hook events earn the block, and how it renders facts handed to it directly — no git, no ledger, no clock beyond the `now` each test controls.
struct SessionResumeBlockTests {
    @Test
    func onlyClearAndCompactSessionStartsEarnTheBlock() {
        let inside = SessionContext.insideRoot("/repo")

        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "clear", context: inside))
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "compact", context: inside))
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "startup", context: inside) == false)
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "resume", context: inside) == false)
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: nil, context: inside) == false)
        #expect(SessionResumeBlock.applies(hookEvent: "SubagentStart", source: "clear", context: inside) == false)
        #expect(SessionResumeBlock.applies(hookEvent: nil, source: "clear", context: inside) == false)
    }

    /// With no Swift in view the primer is silent, and so is the block: branch facts printed after every `/clear` in every other repository on the machine are not this tool's to add.
    @Test
    func silentWhereThePrimerIsSilent() {
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "clear", context: .none) == false)
        #expect(SessionResumeBlock.applies(hookEvent: "SessionStart", source: "compact", context: .none) == false)
        #expect(SessionResumeBlock.applies(
            hookEvent: "SessionStart",
            source: "compact",
            context: .unregisteredSwiftRepository("/repo")
        ))
    }

    @Test
    func silentOnTheDefaultBranchWithACleanTreeAndNoRun() {
        let clean = SessionResumeFacts.BranchPosition(
            branch: "main", defaultBranchName: "main", isDefaultBranch: true, aheadOfDefault: 0, uncommittedFiles: 0
        )

        #expect(SessionResumeBlock.render(SessionResumeFacts(branch: clean), now: Date()) == nil)
        #expect(SessionResumeBlock.render(SessionResumeFacts(), now: Date()) == nil)
    }

    /// The branch line is the one omitted case — everything else that has something to say still says it even on a clean default branch.
    @Test
    func aRunOnTheDefaultBranchWithACleanTreeStillShowsTheRunLine() throws {
        let clean = SessionResumeFacts.BranchPosition(
            branch: "main", defaultBranchName: "main", isDefaultBranch: true, aheadOfDefault: 0, uncommittedFiles: 0
        )
        let facts = SessionResumeFacts(
            branch: clean,
            lastRun: SessionResumeFacts.LastRun(kind: "swift test", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: Date())
        )

        let block = try #require(SessionResumeBlock.render(facts, now: Date()))

        #expect(block.contains("main:") == false)
        #expect(block.contains("last `sift run`"))
    }

    @Test
    func uncommittedWorkOnTheDefaultBranchStillShowsTheBranchLine() throws {
        let dirty = SessionResumeFacts.BranchPosition(
            branch: "main", defaultBranchName: "main", isDefaultBranch: true, aheadOfDefault: 0, uncommittedFiles: 2
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: dirty), now: Date()))

        #expect(block.contains("2 files uncommitted"))
    }

    @Test
    func aFeatureBranchNamesHowFarItHasMoved() throws {
        let feature = SessionResumeFacts.BranchPosition(
            branch: "feat/thing", defaultBranchName: "main", isDefaultBranch: false, aheadOfDefault: 5, uncommittedFiles: 1
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: feature), now: Date()))

        #expect(block.contains("feat/thing: 5 commits ahead of main, 1 file uncommitted"))
    }

    @Test
    func theDeclarationCapNamesTheRest() throws {
        let declarations = SessionResumeFacts.ChangedDeclarations(detail: .names(["+Foo.bar", "~Baz.qux"], moreCount: 3))

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(declarations: declarations), now: Date()))

        #expect(block.contains("declarations changed: +Foo.bar, ~Baz.qux, +3 more — `sift diff` has the rest"))
    }

    @Test
    func noOverflowNamesNoMoreCount() throws {
        let declarations = SessionResumeFacts.ChangedDeclarations(detail: .names(["+Foo.bar"], moreCount: 0))

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(declarations: declarations), now: Date()))

        #expect(block.contains("+Foo.bar") && !block.contains("more"))
    }

    @Test
    func theBudgetOrFileCapFallbackNamesAFileCountInstead() throws {
        let declarations = SessionResumeFacts.ChangedDeclarations(detail: .fileCountFallback(12))

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(declarations: declarations), now: Date()))

        #expect(block.contains("12 Swift files changed — `sift diff` has the declarations"))
    }

    @Test
    func aPassingRunNamesItsAge() throws {
        let now = Date()
        let lastRun = SessionResumeFacts.LastRun(
            kind: "swift build", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: now.addingTimeInterval(-300)
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(lastRun: lastRun), now: now))

        #expect(block.contains("swift build — passed, 5m ago"))
        #expect(block.contains("tree has changed") == false)
    }

    @Test
    func aFailingRunNamesUpToThreeFailures() throws {
        let lastRun = SessionResumeFacts.LastRun(
            kind: "swift test", exitCode: 1,
            failedTests: ["GizmoTests", "DepotKitTests", "AlphaTests", "CatalogueStore", "OrchardApp"], failedTotal: 5,
            timestamp: Date()
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(lastRun: lastRun), now: Date()))

        #expect(block.contains("5 failed (GizmoTests, DepotKitTests, AlphaTests +2 more)"))
    }

    @Test
    func aBuildFailureWithNoNamedTestsReadsAsPlainlyFailed() throws {
        let lastRun = SessionResumeFacts.LastRun(kind: "swift build", exitCode: 1, failedTests: [], failedTotal: 0, timestamp: Date())

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(lastRun: lastRun), now: Date()))

        #expect(block.contains("swift build — failed"))
    }

    @Test
    func aCommitAfterTheRunReadsAsChangedSince() throws {
        let ranAt = Date().addingTimeInterval(-600)
        let facts = SessionResumeFacts(
            lastRun: SessionResumeFacts.LastRun(kind: "swift test", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: ranAt),
            latestCommitDate: ranAt.addingTimeInterval(60)
        )

        let block = try #require(SessionResumeBlock.render(facts, now: Date()))

        #expect(block.contains("tree has changed since"))
    }

    @Test
    func aLaterFileModificationAlsoReadsAsChangedSince() throws {
        let ranAt = Date().addingTimeInterval(-600)
        let facts = SessionResumeFacts(
            lastRun: SessionResumeFacts.LastRun(kind: "swift test", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: ranAt),
            latestChangedFileModificationDate: ranAt.addingTimeInterval(60)
        )

        let block = try #require(SessionResumeBlock.render(facts, now: Date()))

        #expect(block.contains("tree has changed since"))
    }

    @Test
    func nothingNewerThanTheRunReadsAsCurrent() throws {
        let ranAt = Date()
        let facts = SessionResumeFacts(
            lastRun: SessionResumeFacts.LastRun(kind: "swift test", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: ranAt),
            latestCommitDate: ranAt.addingTimeInterval(-3600),
            latestChangedFileModificationDate: ranAt.addingTimeInterval(-3600)
        )

        let block = try #require(SessionResumeBlock.render(facts, now: ranAt.addingTimeInterval(30)))

        #expect(block.contains("tree has changed") == false)
    }

    /// On the default branch there is nothing to be ahead of, so the line is the branch and its uncommitted count alone.
    @Test
    func theDefaultBranchWithUncommittedWorkSaysNothingAboutBeingAhead() throws {
        let dirty = SessionResumeFacts.BranchPosition(
            branch: "main", defaultBranchName: "main", isDefaultBranch: true, aheadOfDefault: 0, uncommittedFiles: 1
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: dirty), now: Date()))

        #expect(block.contains("- main, 1 file uncommitted"))
        #expect(block.contains("ahead of") == false)
    }

    @Test
    func aDetachedHeadIsNamedByItsHash() throws {
        let detached = SessionResumeFacts.BranchPosition(
            branch: nil, headShortHash: "1a2b3c4", defaultBranchName: "main", isDefaultBranch: false, aheadOfDefault: 2, uncommittedFiles: 0
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: detached), now: Date()))

        #expect(block.contains("- detached HEAD at 1a2b3c4: 2 commits ahead of main"))
        #expect(!block.contains("0 files uncommitted"))
    }

    /// An uncommitted count git could not list is left out, never shown as a zero nobody measured.
    @Test
    func anUnlistableUncommittedCountIsLeftOutRatherThanShownAsZero() throws {
        let feature = SessionResumeFacts.BranchPosition(
            branch: "feat/thing", defaultBranchName: "main", isDefaultBranch: false, aheadOfDefault: 3, uncommittedFiles: nil
        )
        let detached = SessionResumeFacts.BranchPosition(
            branch: nil, headShortHash: "1a2b3c4", defaultBranchName: "main", isDefaultBranch: false, aheadOfDefault: 2, uncommittedFiles: nil
        )

        let featureBlock = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: feature), now: Date()))
        let detachedBlock = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: detached), now: Date()))

        #expect(featureBlock.contains("- feat/thing: 3 commits ahead of main"))
        #expect(detachedBlock.contains("- detached HEAD at 1a2b3c4: 2 commits ahead of main"))
        #expect(featureBlock.contains("uncommitted") == false)
        #expect(detachedBlock.contains("uncommitted") == false)
    }

    /// With no default branch to measure against, a branch is worth a line only for its uncommitted work.
    @Test
    func noDefaultBranchLeavesOutTheAheadCount() throws {
        let dirty = SessionResumeFacts.BranchPosition(
            branch: "trunk", defaultBranchName: nil, isDefaultBranch: false, aheadOfDefault: nil, uncommittedFiles: 1
        )
        let clean = SessionResumeFacts.BranchPosition(
            branch: "trunk", defaultBranchName: nil, isDefaultBranch: false, aheadOfDefault: nil, uncommittedFiles: 0
        )

        let block = try #require(SessionResumeBlock.render(SessionResumeFacts(branch: dirty), now: Date()))

        #expect(block.contains("- trunk, 1 file uncommitted"))
        #expect(SessionResumeBlock.render(SessionResumeFacts(branch: clean), now: Date()) == nil)
    }

    /// Every staleness signal is compared against the run's start, not the moment its record was written.
    @Test
    func eachMovementAfterTheRunsStartReadsAsChangedSince() throws {
        let finished = Date().addingTimeInterval(-300)
        let lastRun = SessionResumeFacts.LastRun(
            kind: "swift test", exitCode: 0, failedTests: [], failedTotal: 0, timestamp: finished, durationMilliseconds: 600_000
        )
        let duringTheRun = finished.addingTimeInterval(-120)
        let signals = [
            SessionResumeFacts(lastRun: lastRun, latestCommitDate: duringTheRun),
            SessionResumeFacts(lastRun: lastRun, latestChangedFileModificationDate: duringTheRun),
            SessionResumeFacts(lastRun: lastRun, headReflogModificationDate: duringTheRun),
            SessionResumeFacts(lastRun: lastRun, stashReflogModificationDate: duringTheRun),
            SessionResumeFacts(lastRun: lastRun, hasUndatedChange: true),
        ]

        for facts in signals {
            let block = try #require(SessionResumeBlock.render(facts, now: Date()))
            #expect(block.contains("tree has changed since"))
        }
    }
}
