//
// Copyright © Agulhas Labs
//

import Foundation

/// What the session-start resumption block has to say.
///
/// Gathered independently of one another so that one failing to resolve — no default branch, an unreadable ledger, a merge base that does not exist — never silences the others. Every field is a plain value: nothing here reads git, the run ledger or a file's mtime itself, which is what lets ``SessionResumeBlock/render(_:now:)`` be tested without either.
///
/// **The staleness fields are time-based.** Each is the latest moment something that could change what a run measured is known to have happened, and any one of them later than the run's start (``LastRun/startedAt``) marks its verdict as describing an earlier tree. None of them is ever shown itself.
public struct SessionResumeFacts: Sendable, Equatable {
    public var branch: BranchPosition?
    public var declarations: ChangedDeclarations?
    public var lastRun: LastRun?

    /// `HEAD`'s own committer date — `nil` when there is no commit to date, or it could not be read.
    public var latestCommitDate: Date?

    /// The latest modification time among the files that are dirty now — staged, unstaged or untracked — for an edit that has not been committed.
    public var latestChangedFileModificationDate: Date?

    /// When `HEAD`'s reflog was last written.
    ///
    /// Every checkout, reset, pull, merge, rebase and commit appends to it — including the ones that move `HEAD` to a commit older than the run, which the commit date alone would never show.
    public var headReflogModificationDate: Date?

    /// When the stash's reflog was last written: a `git stash` takes uncommitted work out of the tree without moving `HEAD` or leaving a dirty file behind to date it.
    public var stashReflogModificationDate: Date?

    /// Whether the tree holds a change with no modification time to date it by.
    ///
    /// A dirty deletion, the vanished source of a rename, a dirty path that could not be read, a dirty set git could not list, or a `HEAD` whose reflog is missing. Any one marks a run stale: with nothing to prove the change predates the run, the block errs toward "changed since".
    public var hasUndatedChange: Bool

    public init(
        branch: BranchPosition? = nil,
        declarations: ChangedDeclarations? = nil,
        lastRun: LastRun? = nil,
        latestCommitDate: Date? = nil,
        latestChangedFileModificationDate: Date? = nil,
        headReflogModificationDate: Date? = nil,
        stashReflogModificationDate: Date? = nil,
        hasUndatedChange: Bool = false
    ) {
        self.branch = branch
        self.declarations = declarations
        self.lastRun = lastRun
        self.latestCommitDate = latestCommitDate
        self.latestChangedFileModificationDate = latestChangedFileModificationDate
        self.headReflogModificationDate = headReflogModificationDate
        self.stashReflogModificationDate = stashReflogModificationDate
        self.hasUndatedChange = hasUndatedChange
    }
}

public extension SessionResumeFacts {
    /// Where `HEAD` stands against the default branch — commits ahead of its merge base, and how much of the tree is uncommitted.
    struct BranchPosition: Sendable, Equatable {
        /// The branch's short name, or `nil` on a detached `HEAD`.
        public let branch: String?
        /// `HEAD`'s abbreviated hash, which is what a detached `HEAD` is named by — `nil` on a branch, or when git could not abbreviate it.
        public let headShortHash: String?
        /// `nil` when no default branch resolves: no `origin/HEAD`, and no local `main` or `master`.
        public let defaultBranchName: String?
        public let isDefaultBranch: Bool
        /// Commits `HEAD` has that the default branch lacks — `nil` when there is no default branch to count against, or git could not count.
        public let aheadOfDefault: Int?
        /// Dirty paths — `nil` when git could not list them, so the line says nothing rather than a false zero.
        public let uncommittedFiles: Int?

        public init(
            branch: String?,
            headShortHash: String? = nil,
            defaultBranchName: String?,
            isDefaultBranch: Bool,
            aheadOfDefault: Int?,
            uncommittedFiles: Int?
        ) {
            self.branch = branch
            self.headShortHash = headShortHash
            self.defaultBranchName = defaultBranchName
            self.isDefaultBranch = isDefaultBranch
            self.aheadOfDefault = aheadOfDefault
            self.uncommittedFiles = uncommittedFiles
        }
    }

    /// The declarations changed since the merge base, or what to say instead when gathering the real list was not affordable.
    struct ChangedDeclarations: Sendable, Equatable {
        public let detail: Detail

        public init(detail: Detail) {
            self.detail = detail
        }
    }

    /// The last `sift run` recorded for this exact root, within the window the block still trusts.
    struct LastRun: Sendable, Equatable {
        public let kind: String
        public let exitCode: Int32
        /// Tests this run named as failing — bounded by ``RunUsageLog/failedTestCap``, same as the record itself.
        public let failedTests: [String]
        /// How many distinct tests failed, before that cap — `0` on a clean run.
        public let failedTotal: Int
        /// When the run finished: the record's `ts`, written as the run ends.
        public let timestamp: Date
        /// How long the run took — the record's `ms`, `0` for a record that carries none.
        public let durationMilliseconds: Int

        public init(kind: String, exitCode: Int32, failedTests: [String], failedTotal: Int, timestamp: Date, durationMilliseconds: Int = 0) {
            self.kind = kind
            self.exitCode = exitCode
            self.failedTests = failedTests
            self.failedTotal = failedTotal
            self.timestamp = timestamp
            self.durationMilliseconds = durationMilliseconds
        }

        /// When the run started — the moment every staleness comparison is made against.
        ///
        /// Not ``timestamp``: a file edited while a long test phase was still running was never compiled into what it measured, yet its modification time is earlier than the moment the record was written. The record's `ts` carries whole seconds, so this can land up to a second early, which errs toward "changed since".
        public var startedAt: Date {
            timestamp.addingTimeInterval(-Double(durationMilliseconds) / 1000)
        }
    }
}

public extension SessionResumeFacts.ChangedDeclarations {
    enum Detail: Sendable, Equatable {
        /// The first names, and how many more there were past the cap — `0` when every changed declaration is named.
        case names([String], moreCount: Int)
        /// The wall-clock budget, the file cap or the file-size cap was reached before the declarations could be gathered; this many Swift files changed regardless.
        case fileCountFallback(Int)
    }
}
