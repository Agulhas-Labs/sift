//
// Copyright © Agulhas Labs
//

import Foundation

/// Why a set-aside was refused, or could not be put back — each worded as what happened and what would make it go through.
///
/// **Every failure while the work is out of the tree says so in plain words** — that it is not back, that nothing was deleted, where the copies are, and the command that puts them back — however it came about: a failed check, a git error, a lock another git held. A bare git message over a tree missing somebody's work reads as the work being gone.
public enum SetAsideError: Error, CustomStringConvertible, Sendable {
    case notARepository
    /// An unborn branch: there is no commit for the tree to be set aside to.
    case noCommit
    /// Nothing under the pathspecs differs from HEAD; the flag says whether they name any file at all, since a typo and a clean tree need different next moves — and the paths under this tool's own directory, which a set-aside never moves — and the branch's merge-base with the default branch when the commits since it change the pathspecs, which is what `--since` would set aside.
    case nothingUncommitted(pathspecs: [String], matchesFiles: Bool, leftInPlace: [String], committedSince: String?)
    /// A `--since` run found uncommitted changes under its pathspecs: the paths that hold them, what was named, and the commit it would have set aside to.
    case uncommittedUnder(paths: [String], pathspecs: [String], since: String)
    /// Nothing under the pathspecs changed between the `--since` revision and HEAD, so there is nothing committed to set aside.
    case nothingSince(pathspecs: [String], since: String, matchesFiles: Bool, leftInPlace: [String])
    /// A path in a state this cannot reproduce exactly, so it refuses rather than approximate somebody's work.
    ///
    /// `flag` names the run that found it — `--without` or `--without-line` — so the refusal reads as the caller's own command.
    case unsupported(path: String, reason: String, flag: String)
    /// Another process holds the set-aside lock for this working tree: who, as it wrote itself down, and whether changes are out of the tree while it does.
    case busy(holder: SetAsideLock.Holder?, record: SetAsideRecord?)
    /// A record from a set-aside whose process is gone, and so was never put back.
    case unrestored(SetAsideRecord)
    case unreadableRecord(path: String, reason: String)
    /// A git command the set-aside depends on failed.
    case git(String)
    /// A git command could not take the index lock, for as long as a restore waits for it.
    case indexLocked(String)
    /// The store under `.sift/` could not be written.
    case store(String)
    /// The watcher that restores the tree if this process is killed could not be started, so nothing was set aside.
    case guardUnavailable(String)
    /// A path was written between being recorded and being set aside, so the set-aside stopped; what it had already set aside is back and checked, and nothing was run.
    case changedDuringSetAside([String])
    /// The tree was not put back — why, and where everything was kept.
    case notRestored(NotRestored)
    /// An interruption arrived while the changes were being recorded, before anything in the tree was touched; the copies made so far are gone with it.
    case cancelled
}

public extension SetAsideError {
    /// What a failed restore owes its reader.
    struct NotRestored: Sendable {
        /// What stands in the way — each difference the check found, or the error that stopped the restore.
        public let reasons: [String]
        /// The flag and what it named, as the run was invoked — ``SetAsideRecord/invocation``.
        public let invocation: String
        /// Where the record and the copies are, repository-relative.
        public let store: String
        public let id: String
        /// Whether another git held the index lock — the one cause with a next move of its own.
        public let indexLocked: Bool
        /// Whether this was a restore somebody asked for, after which the manual way out is worth naming.
        public let requested: Bool

        public init(reasons: [String], invocation: String, store: String, id: String, indexLocked: Bool = false, requested: Bool = false) {
            self.reasons = reasons
            self.invocation = invocation
            self.store = store
            self.id = id
            self.indexLocked = indexLocked
            self.requested = requested
        }
    }

    /// The same failure, marked as one a caller asked for by name.
    var requested: SetAsideError {
        guard case let .notRestored(failure) = self else {
            return self
        }
        return .notRestored(NotRestored(
            reasons: failure.reasons,
            invocation: failure.invocation,
            store: failure.store,
            id: failure.id,
            indexLocked: failure.indexLocked,
            requested: true
        ))
    }

    /// Whether this error means somebody's changes are out of the tree right now.
    var workIsOut: Bool {
        switch self {
        case .notRestored, .unrestored, .unreadableRecord: true
        default: false
        }
    }

    /// The part of `error` that says what went wrong, without the prefix a whole message carries — for a sentence that states the rest.
    static func reason(_ error: Error) -> String {
        switch error as? SetAsideError {
        case let .store(message)?, let .git(message)?, let .indexLocked(message)?: message
        default: "\(error)"
        }
    }
}

public extension SetAsideError.NotRestored {
    /// Whether what stopped it was the volume filling up — which has a next move of its own, and which retrying alone will not get past.
    var noSpace: Bool {
        let full = String(cString: strerror(ENOSPC))
        return reasons.contains { $0.contains(full) }
    }
}

extension SetAsideError {
    public var description: String {
        switch self {
        case .notARepository:
            "sift run --without: the current directory is not inside a git working tree, so there is nothing it could set aside."
        case .noCommit:
            "sift run --without: this branch has no commit yet, so there is no version of the tree to set the changes aside to."
        case let .nothingUncommitted(pathspecs, matchesFiles, leftInPlace, committedSince):
            nothingUncommitted(pathspecs.joined(separator: " "), matchesFiles: matchesFiles, leftInPlace: leftInPlace, committedSince: committedSince)
        case let .uncommittedUnder(paths, pathspecs, since):
            "sift run --without: \(pathspecs.joined(separator: " ")) has uncommitted changes — \(Self.listed(paths)) — and --since \(Self.shown(since)) sets aside a committed change, which is never mixed with one in the tree. Commit them, or drop --since to set them aside instead. Nothing was touched."
        case let .nothingSince(pathspecs, since, matchesFiles, leftInPlace):
            nothingSince(pathspecs.joined(separator: " "), since: since, matchesFiles: matchesFiles, leftInPlace: leftInPlace)
        case let .unsupported(path, reason, flag):
            "sift run \(flag): refusing to set aside \(path) — \(reason). Nothing was touched."
        case let .busy(holder, record):
            busy(holder, record: record)
        case let .unrestored(record):
            unrestored(record)
        case let .unreadableRecord(path, reason):
            "a set-aside record exists at \(path) but could not be read (\(reason)). Nothing has been deleted: the copies it points at are beside it, and `sift run` and `sift reset` refuse until the record is dealt with."
        case let .git(message):
            "sift run --without: \(message)"
        case let .indexLocked(message):
            "sift run --without: another git held the index lock for longer than a restore waits: \(message)"
        case let .store(message):
            "sift run --without: \(message)"
        case let .guardUnavailable(reason):
            "sift run --without: could not start the watcher that puts the tree back if this process is killed (\(reason)), so nothing was set aside."
        case let .changedDuringSetAside(paths):
            changedDuringSetAside(paths)
        case let .notRestored(failure):
            notRestored(failure)
        case .cancelled:
            "sift run --without: interrupted while the changes were being recorded, before anything in the working tree was touched; nothing was set aside and nothing was run."
        }
    }

    private func nothingUncommitted(_ named: String, matchesFiles: Bool, leftInPlace: [String], committedSince: String?) -> String {
        guard leftInPlace.isEmpty else {
            let paths = leftInPlace.count == 1 ? leftInPlace[0] : "\(leftInPlace.count) paths under \(SiftPaths.directoryName)/"
            return "sift run --without: the only uncommitted changes under \(named) are in \(paths) — this tool's own directory, which a set-aside never moves — so there is nothing to set aside. Nothing was run."
        }
        guard matchesFiles else {
            return "sift run --without: \(named) matches no file git knows of in this working tree — a pathspec is read relative to the current directory, so check the path. Nothing was run."
        }
        if let committedSince {
            let base = Self.shown(committedSince)
            return "sift run --without: nothing uncommitted under \(named) — the commits since \(base) change it: to set those aside, add --since \(base). Nothing was run."
        }
        return "sift run --without: nothing uncommitted under \(named) — every file it matches is as HEAD has it, so there is nothing to set aside and nothing a run without it could prove. Nothing was run."
    }

    private func nothingSince(_ named: String, since: String, matchesFiles: Bool, leftInPlace: [String]) -> String {
        guard leftInPlace.isEmpty else {
            let paths = leftInPlace.count == 1 ? leftInPlace[0] : "\(leftInPlace.count) paths under \(SiftPaths.directoryName)/"
            return "sift run --without: the only changes under \(named) since \(Self.shown(since)) are in \(paths) — this tool's own directory, which a set-aside never moves — so there is nothing to set aside. Nothing was run."
        }
        guard matchesFiles else {
            return "sift run --without: \(named) matches no file git knows of in this working tree — a pathspec is read relative to the current directory, so check the path. Nothing was run."
        }
        return "sift run --without: nothing under \(named) changed since \(Self.shown(since)) — every file it matches reads there as it does now, so there is nothing to set aside and nothing a run without it could prove. Nothing was run."
    }

    /// A few paths named outright, and the rest counted: a refusal is one sentence, whatever it found.
    private static func listed(_ paths: [String]) -> String {
        let named = paths.prefix(5)
        let rest = paths.count - named.count
        return named.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// A commit as a refusal names it: short enough to read, long enough to find.
    private static func shown(_ commit: String) -> String {
        String(commit.prefix(10))
    }

    private func busy(_ holder: SetAsideLock.Holder?, record: SetAsideRecord?) -> String {
        switch holder?.role {
        case .watcher:
            let owner = record.map { " (pid \($0.owner))" } ?? ""
            return "the `sift run --without` that set changes aside here\(owner) is gone, and its watcher (pid \(holder?.pid ?? 0)) is putting them back now. Wait for it to finish, then run this again."
        case .restore:
            return "a `sift run --restore` (pid \(holder?.pid ?? 0)) is putting set-aside changes back in this working tree. Wait for it to finish, then run this again."
        case .reset:
            return "a `sift reset` (pid \(holder?.pid ?? 0)) is deleting this working tree's \(SiftPaths.directoryName)/. Wait for it to finish, then run this again."
        case .run where record == nil:
            return "a `sift run --without` (pid \(holder?.pid ?? 0)) is running its tests again with the changes back in place. Wait for it to finish, then run this again."
        case .run, nil:
            let pid = holder.map { " (pid \($0.pid))" } ?? ""
            return "a `sift run --without`\(pid) is setting changes aside in this working tree, so the tree is missing some of its uncommitted work until that run finishes. Wait for it: it puts them back itself."
        }
    }

    private func unrestored(_ record: SetAsideRecord) -> String {
        let paths = record.entries.count == 1 ? "1 path" : "\(record.entries.count) paths"
        return """
        this working tree is missing changes a `sift run \(record.invocation)` set aside and never put back (pid \(record.owner) is gone).
          Nothing is lost: \(paths) and their copies are kept under \(SiftPaths.directoryName)/set-aside/.
          Run `sift run --restore` to put them back and check them by content hash; until then `sift run` and `sift reset` refuse.
        """
    }

    private func changedDuringSetAside(_ paths: [String]) -> String {
        var lines = ["sift run --without: the working tree changed while it was being set aside, so it stopped and nothing was run:"]
        lines.append(contentsOf: paths.prefix(20).map { "  \($0) was written after it was recorded, and was left as that write made it" })
        if paths.count > 20 {
            lines.append("  +\(paths.count - 20) more")
        }
        lines.append("  Whatever had been set aside is back in place and checked by content hash. Run it again once nothing else is writing to these paths.")
        return lines.joined(separator: "\n")
    }

    private func notRestored(_ failure: NotRestored) -> String {
        var lines = [
            "✘ the changes `sift run \(failure.invocation)` set aside are NOT back in the working tree — stopping here, and nothing else runs.",
        ]
        lines.append(contentsOf: failure.reasons.prefix(20).map { "  \($0)" })
        if failure.reasons.count > 20 {
            lines.append("  +\(failure.reasons.count - 20) more")
        }
        lines.append("  Nothing has been deleted: the record and a copy of every set-aside file are kept under \(failure.store) (record.json names the path each copy belongs to).")
        if failure.noSpace {
            lines.append("  The volume holding this repository is full. Free some space on it — the restore needs room for the files it puts back and for git's index — then run `sift run --restore`.")
        } else if failure.indexLocked {
            lines.append("  Another git holds .git/index.lock. Once it has finished — or, if no git is running, once you have removed .git/index.lock — run `sift run --restore`.")
        } else {
            lines.append("  Run `sift run --restore` to put them back and check them by content hash.")
        }
        lines.append("  Until then `sift run` and `sift reset` refuse to start.")
        if failure.requested {
            lines.append("  If a path above cannot be put back and is as you want it, `mv \(failure.store.dropLast()) \(SiftPaths.directoryName)/set-aside-kept-\(failure.id.prefix(8))` releases the tree and keeps every copy.")
        }
        return lines.joined(separator: "\n")
    }
}
