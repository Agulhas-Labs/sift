//
// Copyright © Agulhas Labs
//

import Foundation

/// What `diff` compares: two git revisions, or the working tree against `HEAD`.
///
/// A bare `sift diff` reads the same default `affected` reads for an omitted range — the working tree against `HEAD`, untracked files included — so the two commands mean the same thing when run with no argument at all: review what you have not committed yet. `A..B` compares two revisions directly, in the order given. `A...B` is what it means to git: `B` against the merge-base of the two, so a branch is reviewed for what *it* did, never for what the other side did since they parted. A single commit with no `..` (or `X^!`, git's own spelling of the same thing) is read as that commit's own change against its first parent, rather than as "that commit against the working tree", because a review command's single-argument case is almost always "what did this commit do". A root commit has no parent to name, so it diffs against git's own empty-tree object instead: every declaration in it reads as added, never as a refusal.
///
/// Anything else is refused in this tool's own words, naming a spelling that works — a range with an empty side (git would silently fill in `HEAD`, which is a guess about what the caller meant), and a name that resolves to no commit. Handing either to git would fail with its whole usage text, or name an object the caller never typed.
public struct DiffRange: Sendable, Equatable {
    /// Where the comparison's near side reads from — always a revision, since a diff's old side is never the live working tree.
    public let from: String
    public let to: End
    /// What was compared, as the answer's `diff:` line states it — the caller's own spelling first, then what it was resolved to wherever that is not obvious from the spelling.
    public let described: String
    /// The old side as a reader would name it — the revision written, or the short hash of one this tool worked out (a merge-base).
    public let fromLabel: String

    public init(from: String, to: End, described: String, fromLabel: String? = nil) {
        self.from = from
        self.to = to
        self.described = described
        self.fromLabel = fromLabel ?? from
    }
}

public extension DiffRange {
    enum End: Sendable, Equatable {
        case revision(String)
        case workingTree
    }

    /// Why a range argument was not honoured, and what to type instead.
    struct Refusal: Error, Equatable, Sendable {
        public let message: String
    }

    /// Parses a `sift diff` range argument; `nil` (or empty) reads as the working tree against `HEAD`.
    static func resolve(_ argument: String?, git: GitContext) throws -> DiffRange {
        guard let argument = argument?.trimmingCharacters(in: .whitespaces), !argument.isEmpty else {
            let from = git.revisionOrEmptyTree("HEAD")
            return from == "HEAD"
                ? DiffRange(from: from, to: .workingTree, described: "working tree vs HEAD — staged, unstaged and untracked changes")
                : DiffRange(
                    from: from,
                    to: .workingTree,
                    described: "working tree vs an empty repository — no commits yet, so everything present reads as added",
                    fromLabel: "the empty tree"
                )
        }
        if argument.hasSuffix("^!") {
            let commit = String(argument.dropLast(2))
            guard !commit.isEmpty else {
                throw Refusal(message: "sift diff: `\(argument)` names no commit before `^!`. git would read it as HEAD; this tool does not guess — name it: `sift diff HEAD^!`.")
            }
            return try singleCommit(commit, spelled: argument, git: git)
        }
        if let separator = argument.range(of: "...") {
            let left = String(argument[..<separator.lowerBound])
            let right = String(argument[separator.upperBound...])
            guard !left.isEmpty, !right.isEmpty else {
                throw Refusal.emptySide(argument, left: left, right: right, separator: "...", git: git)
            }
            try requireCommits([left, right], in: argument, git: git)
            guard let base = git.mergeBase(left, right) else {
                throw Refusal(message: "sift diff: \(left) and \(right) share no history, so `\(argument)` has no merge-base to compare \(right) against. Compare the two directly: `sift diff \(left)..\(right)`.")
            }
            let label = git.shortHash(base) ?? base
            return DiffRange(
                from: base,
                to: .revision(right),
                described: "\(argument) — \(right) against its merge-base with \(left), \(label)",
                fromLabel: label
            )
        }
        if let separator = argument.range(of: "..") {
            let left = String(argument[..<separator.lowerBound])
            let right = String(argument[separator.upperBound...])
            guard !left.isEmpty, !right.isEmpty else {
                throw Refusal.emptySide(argument, left: left, right: right, separator: "..", git: git)
            }
            try requireCommits([left, right], in: argument, git: git)
            return DiffRange(from: left, to: .revision(right), described: argument)
        }
        return try singleCommit(argument, spelled: argument, git: git)
    }

    /// The `sift affected` invocation that reads this same change set.
    var affectedCommand: String {
        switch to {
        case .workingTree: "sift affected"
        case let .revision(rev): "sift affected --from \(from) --to \(rev)"
        }
    }

    /// The equivalent `affected` range.
    ///
    /// `nil` reads as `affected`'s own default (working tree vs HEAD), which is exactly what this range's own default already means, so the two stay in lockstep with no translation needed at the default.
    var affectedRange: AffectedOptions.CommitRange? {
        switch to {
        case .workingTree: nil
        case let .revision(rev): AffectedOptions.CommitRange(from: from, to: rev)
        }
    }
}

private extension DiffRange {
    /// A single commit read as its own change: against its first parent, or the empty tree when it has none.
    ///
    /// A merge is read against its first parent too — the change the merge brought to the branch it landed on — which is not the combined diff `git show` prints for one, and the answer says so rather than let the two be confused.
    static func singleCommit(_ commit: String, spelled: String, git: GitContext) throws -> DiffRange {
        try requireCommits([commit], in: spelled, git: git)
        let parent = "\(commit)^"
        guard git.resolvesToCommit(parent) else {
            return DiffRange(
                from: GitContext.emptyTreeHash,
                to: .revision(commit),
                described: "\(spelled) — a root commit, against the empty tree: everything in it reads as added",
                fromLabel: "the empty tree"
            )
        }
        let merge = git.resolvesToCommit("\(commit)^2")
        return DiffRange(
            from: parent,
            to: .revision(commit),
            described: merge
                ? "\(spelled) — a merge commit, against its first parent (the change it brought to that branch, not the combined diff `git show` prints)"
                : "\(spelled) — that commit against its parent"
        )
    }

    static func requireCommits(_ revisions: [String], in argument: String, git: GitContext) throws {
        for revision in revisions where !git.resolvesToCommit(revision) {
            let subject = revision == argument ? "`\(revision)`" : "`\(revision)` in `\(argument)`"
            throw Refusal(message: "sift diff: \(subject) does not name a commit in this repository. Pass a commit, branch or tag (`git log --oneline` lists commits), a range such as `main..HEAD` or `main...HEAD`, or nothing at all for the working tree against HEAD.")
        }
    }
}

private extension DiffRange.Refusal {
    /// A range with an empty side, refused with a spelling that names both — and never one that would compare a commit with itself, which is what filling the empty side with `HEAD` gives when the other side is `HEAD` too.
    static func emptySide(_ argument: String, left: String, right: String, separator: String, git: GitContext) -> DiffRange.Refusal {
        let opening = "sift diff: `\(argument)` leaves a side of the range empty. git would fill it in with HEAD; this tool does not guess which end you meant"
        let filled = (left: left.isEmpty ? "HEAD" : left, right: right.isEmpty ? "HEAD" : right)
        let sameCommit = git.shortHash(filled.left).map { $0 == git.shortHash(filled.right) } ?? false
        guard sameCommit || left.isEmpty && right.isEmpty else {
            return DiffRange.Refusal(message: "\(opening) — name both: `sift diff \(filled.left)\(separator)\(filled.right)`.")
        }
        // Filled in, both sides would be one commit, and the comparison would be empty.
        let named = left.isEmpty ? right : left
        let advice = if left.isEmpty, !right.isEmpty {
            "`sift diff \(named)` for that commit's own change, or `sift diff <base>\(separator)\(named)` naming the base"
        } else {
            "`sift diff` with no range for the working tree against HEAD, or `sift diff <base>\(separator)HEAD` naming the base"
        }
        return DiffRange.Refusal(message: "\(opening), and filled in with HEAD it would compare one commit with itself — pass \(advice).")
    }
}

extension DiffRange.End {
    var described: String {
        switch self {
        case .workingTree: "working tree"
        case let .revision(rev): rev
        }
    }
}
