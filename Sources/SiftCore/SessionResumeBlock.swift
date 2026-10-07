//
// Copyright © Agulhas Labs
//

import Foundation

/// The "where you left off" block a `/clear` or `/compact` earns.
///
/// What a fresh context cannot see for itself in the transcript it was just handed instead of the one it lost: facts about the working tree only — never the task, never anything Claude Code's own compaction summary already carries, because duplicating that is not what a fresh context is missing.
///
/// A pure function of ``SessionResumeFacts`` and `now`, so its wording and its staleness rule are unit tested with no git, no ledger file and no clock in sight; ``SessionResumeGatherer`` is the one thing that reads any of those.
public struct SessionResumeBlock {
    /// Whether a `SessionStart` hook firing with this stdin `source`, in this context, should even attempt this block.
    ///
    /// Only `clear` and `compact` are the moments the conversation's own history was just thrown away — `startup` and `resume` restore it, so the same block would only repeat what the model already has. `SubagentStart` carries no `source` that means either of those things, and is refused by `hookEvent` alone. And the block stays silent wherever the primer does: with no Swift in view this tool has nothing to say, and branch facts printed into every other repository on the machine would be noise it has no business adding.
    public static func applies(hookEvent: String?, source: String?, context: SessionContext) -> Bool {
        context != .none && hookEvent == "SessionStart" && (source == "clear" || source == "compact")
    }

    /// The block itself, or `nil` when the working tree has nothing worth saying — no header, no empty block.
    public static func render(_ facts: SessionResumeFacts, now: Date) -> String? {
        var lines: [String] = []

        if let branch = facts.branch, let line = branchLine(branch) {
            lines.append("- \(line)")
        }

        if let declarations = facts.declarations {
            lines.append("- \(declarationsLine(declarations))")
        }

        if let lastRun = facts.lastRun {
            lines.append("- \(lastRunLine(lastRun, facts: facts, now: now))")
        }

        guard !lines.isEmpty else { return nil }
        return (["**Picking back up:**"] + lines).joined(separator: "\n")
    }

    /// `feat: 3 commits ahead of main, 1 file uncommitted`, `feat: 1 commit ahead of main` on a clean feature branch, `main, 1 file uncommitted` on the default branch itself, and `detached HEAD at 1a2b3c4: …` where there is no branch to name.
    ///
    /// `nil` when there is nothing to say beyond a name: a clean default branch, or a clean branch with no default branch to measure it against. A detached `HEAD` is always said — a paused rebase or a bisect is exactly what a fresh context needs telling. The uncommitted fragment itself drops out at zero as well as when git could not list the dirty set — a clean branch has nothing to add there.
    private static func branchLine(_ branch: SessionResumeFacts.BranchPosition) -> String? {
        let name = branch.branch ?? ("detached HEAD" + (branch.headShortHash.map { " at \($0)" } ?? ""))
        // `nil` at zero as well as when git could not list the dirty set: a clean branch has nothing to
        // add here, and "0 files uncommitted" would read as a claim rather than an absence.
        let uncommitted = branch.uncommittedFiles.flatMap { $0 > 0 ? "\(plural($0, "file")) uncommitted" : nil }

        if branch.isDefaultBranch {
            guard let count = branch.uncommittedFiles, count > 0, let uncommitted else { return nil }
            return "\(name), \(uncommitted)"
        }
        if let ahead = branch.aheadOfDefault, let defaultBranchName = branch.defaultBranchName {
            let position = "\(name): \(plural(ahead, "commit")) ahead of \(defaultBranchName)"
            return uncommitted.map { "\(position), \($0)" } ?? position
        }
        guard branch.branch == nil || (branch.uncommittedFiles ?? 0) > 0 else { return nil }
        return ([name] + [uncommitted].compactMap(\.self)).joined(separator: ", ")
    }

    private static func declarationsLine(_ declarations: SessionResumeFacts.ChangedDeclarations) -> String {
        switch declarations.detail {
        case let .names(names, moreCount):
            let rest = moreCount > 0 ? ", +\(moreCount) more — `sift diff` has the rest" : ""
            return "declarations changed: " + names.joined(separator: ", ") + rest
        case let .fileCountFallback(count):
            return "\(plural(count, "Swift file")) changed — `sift diff` has the declarations"
        }
    }

    private static func lastRunLine(_ lastRun: SessionResumeFacts.LastRun, facts: SessionResumeFacts, now: Date) -> String {
        let verdict: String
        if lastRun.exitCode == 0 {
            verdict = "passed"
        } else if !lastRun.failedTests.isEmpty {
            let named = lastRun.failedTests.prefix(3).joined(separator: ", ")
            let more = lastRun.failedTotal > 3 ? " +\(lastRun.failedTotal - 3) more" : ""
            verdict = "\(lastRun.failedTotal) failed (\(named)\(more))"
        } else {
            verdict = "failed"
        }
        let staleNote = isStale(lastRun: lastRun, facts: facts) ? " — tree has changed since" : ""
        return "last `sift run`: \(lastRun.kind) — \(verdict), \(age(of: lastRun.timestamp, now: now))\(staleNote)"
    }

    /// Whether `lastRun`'s verdict predates the tree it would otherwise be read as describing.
    ///
    /// Measured from the run's *start*: whatever changed after that — a commit, a checkout or reset, a stash, an edit, a deletion — was not what it measured, even when it happened before the run finished.
    private static func isStale(lastRun: SessionResumeFacts.LastRun, facts: SessionResumeFacts) -> Bool {
        if facts.hasUndatedChange {
            return true
        }
        let movements = [
            facts.latestCommitDate,
            facts.latestChangedFileModificationDate,
            facts.headReflogModificationDate,
            facts.stashReflogModificationDate,
        ]
        return movements.compactMap(\.self).contains { $0 > lastRun.startedAt }
    }

    private static func age(of date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 {
            return "just now"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
