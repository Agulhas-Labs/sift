//
// Copyright © Agulhas Labs
//

import Foundation

/// What `run --without` took out of the working tree, written to disk before the tree is touched: enough to put every byte back with no process left alive to remember anything.
///
/// **The record is the recovery, not a log of it.** The process that set the changes aside can be killed at any instruction, and so can the one watching it, so nothing about how to restore may live anywhere but here: every path, what the index held for it, what the working tree held for it, and where a byte-for-byte copy of each file stands. While this file exists `sift run` refuses to start, because every build it could run would build a tree that is missing somebody's work.
public struct SetAsideRecord: Codable, Sendable, Equatable {
    /// The layout this binary writes, so a record from another version is refused rather than misread.
    public static let currentFormat = 2

    public let format: Int
    /// Which set-aside this is — what a watcher checks before restoring, so it can never restore a record a later run wrote.
    public let id: String
    /// What the caller named, verbatim, and the directory they named it from — repository-relative, empty for the root — because a pathspec means what it means relative to where it was written.
    public let pathspecs: [String]
    public let directory: String
    /// The commit HEAD named when the record was made.
    ///
    /// Only ever compared, never restored to: the restore puts back the bytes and the index entries, which are what the caller had, and a HEAD that moved while the tests ran is reported rather than undone.
    public let head: String
    /// The commit whose version of each path the set-aside places, where `--since` named one, and `nil` where it is HEAD's — what a caller sets aside a committed change to.
    ///
    /// Nothing a restore does reads it: a restore puts back the bytes and index entries recorded below, whatever was placed over them, which is why a record written before this field existed still restores exactly. It is the record's own account of what was set aside, for the sentences that name it.
    public let since: String?
    /// The process that made the record, named in refusals and nothing else.
    ///
    /// Whether it is still alive is decided by the lock it holds, which cannot outlive it, and never by this number.
    public let owner: Int32
    public let entries: [Entry]
    /// Paths under the pathspec that git reported as changed and that were never moved, because they are this tool's own — said in the answer, so a path left in place is never a path silently skipped.
    public let leftInPlace: [String]
    /// The one line a `run --without-line` commented out, where that is what was set aside, and `nil` for a `run --without`.
    ///
    /// Nothing a restore does reads it, as with ``since``: the file comes back from its copy like any other, so a record written before this field existed loads and restores unchanged, and the format stays the same. It is what the sentences that name the set-aside name instead of a pathspec.
    public let line: MutatedLine?

    public init(id: String, pathspecs: [String], directory: String, head: String, since: String? = nil, owner: Int32, entries: [Entry], leftInPlace: [String] = [], line: MutatedLine? = nil) {
        format = Self.currentFormat
        self.id = id
        self.pathspecs = pathspecs
        self.directory = directory
        self.head = head
        self.since = since
        self.owner = owner
        self.entries = entries
        self.leftInPlace = leftInPlace
        self.line = line
    }
}

public extension SetAsideRecord {
    /// One path a set-aside touches: what the commit it is set aside to, the index and the working tree each held for it.
    struct Entry: Codable, Sendable, Equatable {
        /// Repository-relative, exactly as git printed it — the spelling every git command is given.
        public let path: String
        /// The same path in the bytes the file system holds it under, where those differ from git's: git precomposes a decomposed name, and a name put back in other bytes has not been put back exactly.
        public let disk: String?
        /// git's own `status --porcelain=v2` fields for this path, less the path itself — what the answer's split between staged, unstaged and untracked is counted from; empty where the change being set aside is a committed one, which is none of the three.
        public let status: String
        /// The entry of the commit this path is set aside to — HEAD's, or the one a `--since` revision names — or `nil` where that commit has no such path.
        public let head: IndexEntry?
        public let index: IndexState
        public let worktree: WorktreeState

        public init(path: String, disk: String? = nil, status: String, head: IndexEntry?, index: IndexState, worktree: WorktreeState) {
            self.path = path
            self.disk = disk
            self.status = status
            self.head = head
            self.index = index
            self.worktree = worktree
        }

        /// The spelling every file-system call is made with.
        public var onDisk: String {
            disk ?? path
        }

        /// Whether the set-aside has to write this path's index entry: it differs from the one it is set aside to, and it is not an intent-to-add entry, which no index write could put back.
        var indexDiffersFromHead: Bool {
            switch index {
            case .intentToAdd: false
            case .absent: head != nil
            case let .entry(staged): staged != head
            }
        }

        /// What the set-aside leaves in the index for this path: the entry it is set aside to where it writes one, and otherwise what was recorded.
        var indexAside: IndexState {
            guard indexDiffersFromHead else {
                return index
            }
            return head.map { .entry($0) } ?? .absent
        }
    }

    /// A mode and an object, as the index and a tree both spell an entry.
    struct IndexEntry: Codable, Sendable, Equatable {
        public let mode: String
        public let object: String

        public init(mode: String, object: String) {
            self.mode = mode
            self.object = object
        }
    }

    /// What the index held for a path — the whole of it, whether or not it differs from HEAD, because that is what a restore puts back and checks, whatever HEAD has become in the meantime.
    enum IndexState: Codable, Sendable, Equatable {
        /// No entry: untracked, or staged as deleted.
        case absent
        /// This entry, at stage 0.
        case entry(IndexEntry)
        /// An intent-to-add entry, which no index write could reproduce — `git add -N` has no plumbing spelling — so the set-aside leaves it where it is.
        case intentToAdd
    }

    /// What the working tree held at a path.
    enum WorktreeState: Codable, Sendable, Equatable {
        case absent
        /// A regular file: its permission bits, the SHA-256 of its bytes, and the copy's name in the store.
        case file(permissions: Int, sha256: String, copy: String)
        case symlink(target: String)
    }

    /// How many entries had something staged, how many something unstaged, and how many were untracked — the split an answer states.
    ///
    /// A path can be both staged and unstaged at once, so the first two can add up to more than the entries.
    struct Split: Sendable, Equatable {
        public var staged = 0
        public var unstaged = 0
        public var untracked = 0
    }

    var split: Split {
        entries.reduce(into: Split()) { counts, entry in
            let fields = Array(entry.status)
            if entry.status == "?" {
                counts.untracked += 1
                return
            }
            if fields.count > 3, fields[2] != "." {
                counts.staged += 1
            }
            if fields.count > 3, fields[3] != "." {
                counts.unstaged += 1
            }
        }
    }

    /// The pathspecs as a caller wrote them, or the line as `path:number`, for a sentence.
    var named: String {
        line.map { "\($0.path):\($0.number)" } ?? pathspecs.joined(separator: " ")
    }

    /// `--without` or `--without-line`, whichever this run was made with — for a sentence that names the caller's own flag rather than assuming the other.
    var flag: String {
        line == nil ? "--without" : "--without-line"
    }

    /// The flag and what it named, the way the run was invoked — `--without Sources/`, or `--without-line Sources/Widget.swift:12` — for a sentence that tells the caller which run this was.
    var invocation: String {
        "\(flag) \(named)"
    }

    /// Every path the set-aside takes out of the tree outright rather than rewriting: the commit it is set aside to has no version of it — a new file, staged, untracked, or added by the commits since a `--since` revision — so what stood there is removed and nothing is put in its place.
    ///
    /// What a build makes of that is the whole of the difference: SwiftPM and Xcode both glob a target's sources, so a file that goes takes its declarations with it, and a test that names them stops compiling instead of failing.
    var newFiles: [String] {
        guard line == nil else {
            return []
        }
        return entries.filter { $0.head == nil && $0.worktree != .absent }.map(\.path)
    }
}
