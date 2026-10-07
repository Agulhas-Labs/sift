//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads git, the run ledger and blob content to build ``SessionResumeFacts``.
///
/// Strictly read-only, so a `SessionStart` hook can never trigger an index rebuild. Never opens a ``SiftEngine`` or an ``IndexStore`` for exactly that reason: the declaration comparison goes through ``DiffGatherer``'s own static, storeless `fileDiff(_:old:new:stat:member:)`, parsing each side fresh from bytes this type reads itself, the same way `sift diff` parses a historical revision it holds no index for. Every git it runs goes through ``GitContext``, whose reads never write the index, so not even `git status`'s refresh of it is written back.
///
/// Every fact is gathered independently, so one failing — no default branch, a detached `HEAD`, a merge base that does not exist, an unreadable ledger — only ever drops what it was going to say, never the others.
public struct SessionResumeGatherer {
    /// Swift files parsed for declaration changes before falling back to a bare count.
    public static let defaultFileCap = 50

    /// Wall-clock budget for the declaration comparison, the blob read included.
    ///
    /// Checked before each file, not inside SwiftSyntax's own parse, so it bounds how many files are started rather than preempting one already underway — ``defaultFileSizeCap`` is what keeps any one of them short.
    public static let defaultDeclarationParseBudget: TimeInterval = 0.25

    /// Bytes past which a file's side is not parsed at all, in either revision.
    ///
    /// One large generated file would otherwise take the whole budget inside a single parse. A file over it costs the list, the same as the budget running out.
    public static let defaultFileSizeCap = 256 * 1024

    /// Wall-clock bound on the whole gather.
    ///
    /// Well under the 5-second timeout `install-hook` registers the hook with, so a gather that runs long — a cold monorepo's `git status`, say — costs the block and never the primer printed ahead of it.
    public static let defaultDeadline: TimeInterval = 1.5

    /// Declaration names shown before the rest are counted instead.
    public static let declarationNameCap = 10

    /// Ledger records older than this are never shown — a verdict this stale is not worth trusting over a live `sift run`.
    public static let runRecordMaxAge: TimeInterval = 24 * 60 * 60

    /// How much of the run ledger's end is read.
    ///
    /// Only the last day's records are ever wanted and the ledger only grows, so reading it whole would cost more on every `/clear` for as long as the machine is used.
    public static let ledgerTailBytes = 256 * 1024

    /// The facts, or `nil` when gathering them took longer than `deadline`.
    ///
    /// The gather runs on a thread of its own and is waited for, never cancelled: past the deadline the caller goes on without it, prints the primer alone, and exits — and the process takes the thread with it. A git it had started is left to finish on its own, which is harmless: every one is a read with optional locks off, so there is no lock or half-written file for it to leave behind.
    public static func gather(repositoryRoot: URL?, runLedgerURL: URL, deadline: TimeInterval) -> SessionResumeFacts? {
        bounded(by: deadline) {
            gather(repositoryRoot: repositoryRoot, runLedgerURL: runLedgerURL)
        }
    }

    public static func gather(
        repositoryRoot: URL?,
        runLedgerURL: URL,
        now: Date = Date(),
        fileCap: Int = defaultFileCap,
        fileSizeCap: Int = defaultFileSizeCap,
        declarationParseBudget: TimeInterval = defaultDeclarationParseBudget
    ) -> SessionResumeFacts {
        guard let repositoryRoot else { return SessionResumeFacts() }
        let git = GitContext(repoRoot: repositoryRoot)

        var facts = SessionResumeFacts()
        facts.lastRun = lastRun(repositoryRoot: repositoryRoot, runLedgerURL: runLedgerURL, now: now)

        // What dates the tree comes before anything that needs a branch: a detached HEAD (a paused rebase, a
        // bisect), a repository with no default branch and a branch with no merge base all still have a tree
        // that can have moved since the run.
        let hasHead = resolvedHead(git) != nil
        let dirty = try? git.dirtyFiles()
        recordTreeMovement(into: &facts, dirty: dirty, hasHead: hasHead, git: git, repositoryRoot: repositoryRoot)

        // An unborn branch (no commits yet) has no position to state and no merge base to diff against.
        guard hasHead else { return facts }

        let branchName = git.currentBranch()
        let defaultBranch = git.defaultBranch()
        facts.branch = SessionResumeFacts.BranchPosition(
            branch: branchName,
            headShortHash: branchName == nil ? git.shortHash("HEAD") : nil,
            defaultBranchName: defaultBranch?.name,
            isDefaultBranch: branchName != nil && branchName == defaultBranch?.name,
            aheadOfDefault: defaultBranch.flatMap { try? git.commitCount(from: $0.ref, to: "HEAD") },
            uncommittedFiles: dirty?.count
        )

        // Measured from HEAD, not from the branch's name, so a detached HEAD has a merge base too. Either half
        // of the changeset failing to list drops the declarations whole: a list missing one half would read as
        // complete.
        if let defaultBranch, let dirty,
           let mergeBase = git.mergeBase(defaultBranch.ref, "HEAD"),
           let committed = try? git.changedFiles(from: mergeBase, to: "HEAD")
        {
            facts.declarations = declarations(
                mergeBase: mergeBase,
                comparisons: comparisons(committed: committed, uncommitted: dirty).filter(\.isSwift),
                git: git,
                repositoryRoot: repositoryRoot,
                limits: Limits(fileCap: fileCap, fileSizeCap: fileSizeCap, budget: declarationParseBudget)
            )
        }
        return facts
    }
}

extension SessionResumeGatherer {
    /// One file to compare: its path on disk now, and the path its old side is read from at the merge base.
    struct Comparison: Equatable {
        let path: String
        let basePath: String

        var isSwift: Bool {
            path.hasSuffix(".swift") || basePath.hasSuffix(".swift")
        }

        /// The change `DiffGatherer` compares — a rename where the two paths differ, so the status it files matches what happened.
        var change: GitContext.Change {
            GitContext.Change(kind: basePath == path ? .addedOrModified : .renamed(from: basePath), path: path)
        }
    }

    /// Every path the merge-base→HEAD range and the dirty set touch, once each, paired with the path it had at the merge base.
    ///
    /// A rename is carried through rather than read as an addition: its old side is the *source* path at the merge base, so a file that only moved compares equal and names no declaration. A dirty rename of a path the range already renamed chains back to the range's own source, and a dirty rename's source leaves the list, since nothing is there any more to compare.
    static func comparisons(committed: [GitContext.Change], uncommitted: [GitContext.Change]) -> [Comparison] {
        var basePaths: [String: String] = [:]
        for change in committed {
            basePaths[change.path] = change.renamedFrom ?? change.path
        }
        for change in uncommitted {
            if let source = change.renamedFrom {
                basePaths[change.path] = basePaths.removeValue(forKey: source) ?? source
            } else if basePaths[change.path] == nil {
                basePaths[change.path] = change.path
            }
        }
        return basePaths.map { Comparison(path: $0.key, basePath: $0.value) }.sorted { $0.path < $1.path }
    }

    /// The most recent ledger record for this exact root (worktrees are different roots) inside ``runRecordMaxAge``, or `nil` when there is none.
    ///
    /// The ledger is append-only and chronological (`RunUsageLog`), so scanning from the end, the first line whose root matches is the most recent run for this root there is — and the first line older than the window ends the scan, since nothing further back can be newer. Only the last `tailBytes` are read, and each distinct root is canonicalised once: `CanonicalPath.of` asks the filesystem, and the same few roots fill the whole file.
    static func lastRun(repositoryRoot: URL, runLedgerURL: URL, now: Date, tailBytes: Int = ledgerTailBytes) -> SessionResumeFacts.LastRun? {
        guard let data = ledgerTail(of: runLedgerURL, bytes: tailBytes), !data.isEmpty else { return nil }
        let resolvedRoot = CanonicalPath.of(repositoryRoot.path)
        let cutoff = now.addingTimeInterval(-runRecordMaxAge)
        let formatter = ISO8601DateFormatter()
        var canonical: [String: String] = [:]

        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = (object["ts"] as? String).flatMap(formatter.date(from:))
            else {
                continue
            }
            guard timestamp >= cutoff else { return nil }
            guard let kind = object["kind"] as? String, let root = object["root"] as? String else { continue }
            let resolved = canonical[root] ?? CanonicalPath.of(root)
            canonical[root] = resolved
            guard resolved == resolvedRoot else { continue }
            return SessionResumeFacts.LastRun(
                kind: kind,
                exitCode: Int32(exactly: object["exit"] as? Int ?? 0) ?? 0,
                failedTests: object["failed"] as? [String] ?? [],
                failedTotal: object["failed_total"] as? Int ?? 0,
                timestamp: timestamp,
                durationMilliseconds: object["ms"] as? Int ?? 0
            )
        }
        return nil
    }

    /// `work`'s result, or `nil` when it has not finished `deadline` seconds from now — see the deadline-bounded `gather` for why it is abandoned rather than stopped.
    static func bounded<Value: Sendable>(by deadline: TimeInterval, _ work: @escaping @Sendable () -> Value) -> Value? {
        let outcome = Outcome<Value>()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.store(work())
            finished.signal()
        }
        guard finished.wait(timeout: .now() + deadline) == .success else { return nil }
        return outcome.value
    }
}

private extension SessionResumeGatherer {
    /// The declaration comparison's three bounds, carried together.
    struct Limits {
        let fileCap: Int
        let fileSizeCap: Int
        let budget: TimeInterval
    }

    /// Where the gathering thread leaves its answer for the one waiting on it.
    final class Outcome<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        var value: Value? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func store(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }
    }

    /// `HEAD`, or `nil` for both an unborn branch and a git failure — the two things this block treats alike.
    static func resolvedHead(_ git: GitContext) -> String? {
        guard let head = try? git.head() else { return nil }
        return head
    }

    /// Every signal that the tree has moved, each one dated where it can be: `HEAD`'s commit date, the `HEAD` and stash reflogs' modification times, and the dirty files' own.
    ///
    /// Stats, not git, wherever a stat answers — the reflogs and the dirty files are read straight off disk. Anything that cannot be dated counts as undated rather than as absent: a dirty deletion or a rename's source (no file left to date), a dirty path that will not stat, a dirty set git would not list, and a `HEAD` with no reflog behind it (reflogs turned off), since nothing could then show a checkout or a reset.
    static func recordTreeMovement(
        into facts: inout SessionResumeFacts,
        dirty: [GitContext.Change]?,
        hasHead: Bool,
        git: GitContext,
        repositoryRoot: URL
    ) {
        facts.latestCommitDate = hasHead ? git.commitDate("HEAD") : nil
        if let reflogs = git.gitPaths(["logs/HEAD", "logs/refs/stash"]) {
            facts.headReflogModificationDate = modificationDate(of: reflogs[0])
            facts.stashReflogModificationDate = modificationDate(of: reflogs[1])
        }
        if hasHead, facts.headReflogModificationDate == nil {
            facts.hasUndatedChange = true
        }

        guard let dirty else {
            facts.hasUndatedChange = true
            return
        }
        var latest: Date?
        for change in dirty {
            if case .deleted = change.kind {
                facts.hasUndatedChange = true
                continue
            }
            if change.renamedFrom != nil {
                facts.hasUndatedChange = true
            }
            guard let date = modificationDate(of: repositoryRoot.appendingPathComponent(change.path)) else {
                facts.hasUndatedChange = true
                continue
            }
            latest = max(latest ?? date, date)
        }
        facts.latestChangedFileModificationDate = latest
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func fileSize(of url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    /// Every declaration changed across `comparisons` since `mergeBase`, or the fallback line when a bound was not enough to say so.
    ///
    /// Old-side bytes come from `mergeBase` at each comparison's base path, new-side from disk — including any uncommitted edit — so a declaration edited only in the working tree still shows, and a renamed file is compared with what it was before the move. `DiffGatherer.fileDiff` parses each side fresh and keeps no body (`member: nil`), the same discipline a full `sift diff` observes.
    static func declarations(
        mergeBase: String,
        comparisons: [Comparison],
        git: GitContext,
        repositoryRoot: URL,
        limits: Limits
    ) -> SessionResumeFacts.ChangedDeclarations? {
        guard !comparisons.isEmpty else { return nil }
        let fallback = SessionResumeFacts.ChangedDeclarations(detail: .fileCountFallback(comparisons.count))
        guard comparisons.count <= limits.fileCap else { return fallback }

        // The clock starts before the blob read, so the budget covers everything this comparison costs.
        let deadline = Date().addingTimeInterval(limits.budget)
        guard let oldBlobs = try? git.blobs(comparisons.map { (rev: mergeBase, path: $0.basePath) }) else { return fallback }

        var names: [String] = []
        for (index, comparison) in comparisons.enumerated() {
            guard Date() < deadline else { return fallback }
            let url = repositoryRoot.appendingPathComponent(comparison.path)
            let old = oldBlobs[index]
            guard (old?.count ?? 0) <= limits.fileSizeCap, (fileSize(of: url) ?? 0) <= limits.fileSizeCap else { return fallback }
            let new = try? Data(contentsOf: url)
            guard old != nil || new != nil else { continue }
            let fileDiff = DiffGatherer.fileDiff(comparison.change, old: old, new: new)
            names += fileDiff.changes.filter { $0.kind != .moved }.map { "\(marker($0.kind))\($0.label)" }
        }

        guard !names.isEmpty else { return nil }
        guard names.count > declarationNameCap else {
            return SessionResumeFacts.ChangedDeclarations(detail: .names(names, moreCount: 0))
        }
        return SessionResumeFacts.ChangedDeclarations(
            detail: .names(Array(names.prefix(declarationNameCap)), moreCount: names.count - declarationNameCap)
        )
    }

    static func marker(_ kind: DeclarationChange.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .changed, .moved: "~"
        }
    }

    /// The last `bytes` of the ledger, starting at the first whole line inside them.
    static func ledgerTail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        // One byte early, so a tail that happens to begin on a line's first byte keeps that line: the byte
        // before it is then the newline that is dropped.
        let readFrom = start > 0 ? start - 1 : 0
        guard (try? handle.seek(toOffset: readFrom)) != nil else { return nil }
        let tail = (try? handle.readToEnd()) ?? Data()
        guard start > 0 else { return tail }
        guard let newline = tail.firstIndex(of: 0x0A) else { return Data() }
        return Data(tail[tail.index(after: newline)...])
    }
}
