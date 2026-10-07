//
// Copyright © Agulhas Labs
//

import Foundation

/// The tests a change writes — added or edited — as the bare identifiers a run prints them under.
///
/// `run --without` says of a test that passes both ways that it pins nothing. That is a finding only where the change is what wrote the test: a test the change never touched passing either way is what a suite is for, and listing a line of it per test buries the two lines that mattered. This reads what the change is — the working tree against the branch's merge-base with the default branch, or with `--since` against the revision it names, commits and uncommitted work together — at declaration level rather than by line, so the answer can tell one from the other.
///
/// **Read before anything is set aside.** Once the pathspec's files are the committed versions, a pathspec covering `Tests` would make the working tree lie about what changed, so ``identifiers(since:in:)`` is asked in ``RunWithoutCommand`` ahead of the session that moves them.
///
/// **`nil` is "could not be read", and folds nothing.** Git refusing, an unborn branch or a side that will not read leaves the answer exactly as it is without this: a listing is never made quieter than the evidence behind it. An empty set is the other thing — read, and the change touches no test at all.
public struct ChangedTests {
    /// The tests the change adds or edits, as bare identifiers; `nil` where the range could not be read.
    ///
    /// `since` is the revision `--without --since` named, already resolved. With a revision the change is everything since it — the commits `<rev>..HEAD` and whatever the working tree holds uncommitted beside them — read against `<rev>`. The set-aside refuses uncommitted work only under its own pathspecs, so a test written uncommitted anywhere else runs in both runs, and a range read from its commits alone would fold that test away as untouched.
    ///
    /// Without one the revision is the branch's merge-base with the default branch (``GitContext/defaultBranch()``), not `HEAD`: the usual negative gate commits the test and leaves the fix uncommitted, and read against `HEAD` that committed test would fold away as untouched — so a neighbour in the filter that pins would make the run exit 0 on a test the change never wrote. On the default branch the merge-base is `HEAD` itself, so nothing changes there. Where no merge-base resolves — no default branch to measure against (no `origin/HEAD`, no local `main` or `master`), no history shared with it, a shallow clone cut above it — the change is the working tree against `HEAD`, untracked files included, as it was before.
    public static func identifiers(since: String?, in workingDirectory: URL) -> Set<String>? {
        guard let root = GitContext.discoverRoot(from: workingDirectory) else {
            return nil
        }
        let git = GitContext(repoRoot: root)
        // `try?` flattens git refusing and an unborn branch into the one answer both owe: unreadable.
        guard let head = try? git.head() else {
            return nil
        }
        let since = since ?? git.defaultBranch().flatMap { git.mergeBase($0.ref, head) }
        do {
            var touched: [String: Touched] = [:]
            if let since, since != head {
                for change in try git.changedFiles(from: since, to: head) {
                    touched[change.path] = Touched(before: change.origin, after: change.isDeletion ? .gone : .committed)
                }
            }
            // What the working tree holds uncommitted is read from disk over whatever the commits left at that
            // path, keeping the commits' origin for a file they renamed: the before side is one revision.
            // A dirty rename's own origin is where its earlier side was recorded, committed or not — its
            // own path has never been touched before — so a chain of renames still reads at the first one.
            for change in try git.dirtyFiles() {
                let origin = change.origin
                let before: String
                if case .renamed = change.kind {
                    before = touched[origin]?.before ?? origin
                    touched.removeValue(forKey: origin)
                } else {
                    before = touched[change.path]?.before ?? origin
                }
                touched[change.path] = Touched(before: before, after: change.isDeletion ? .gone : .disk)
            }
            // A test source is a Swift file, so nothing else is read at all: a range's binaries and its
            // fixtures would otherwise each cost a blob and a parse to reach the same answer.
            let files = touched.filter { $0.key.hasSuffix(".swift") }.map { (path: $0.key, touched: $0.value) }
            guard !files.isEmpty else {
                return []
            }
            // A file the change added is at no path on the before side, and `blobs` answers `nil` for one.
            let olds = try git.blobs(files.map { (rev: since ?? head, path: $0.touched.before) })
            let committed = files.filter { $0.touched.after == .committed }.map(\.path)
            let news = try zip(committed, git.blobs(committed.map { (rev: head, path: $0) })).reduce(into: [String: Data]()) { $0[$1.0] = $1.1 }
            var found: Set<String> = []
            for (offset, file) in files.enumerated() {
                let new: Data? = switch file.touched.after {
                case .gone:
                    nil
                case .committed:
                    news[file.path]
                case .disk:
                    // A side that will not read leaves the whole answer unread; read as a deletion instead, the
                    // file's written tests would fold away as untouched.
                    try Data(contentsOf: root.appendingPathComponent(file.path))
                }
                found.formUnion(identifiers(inTestSource: file.path, bytes: (old: olds[offset], new: new)))
            }
            return found
        } catch {
            return nil
        }
    }

    /// The note owed when a run without `--since` measured no branch range at all — the same fold risk as an unresolved merge-base, taken silently unless this says so.
    ///
    /// `since` is `--without --since`'s already-resolved revision, as read by ``identifiers(since:in:)``: given one, a range was asked for outright and nothing here applies. Without one, the range is the branch's merge-base with the default branch, and it can be `HEAD` itself for reasons that call for very different answers. A branch already fast-forwarded into the default branch locally (`git branch -f main feature`, still checked out on `feature`) reads no committed range at all — `HEAD` is not the default branch, yet its merge-base with it is `HEAD` all the same — and a committed test beside the fix would fold away exactly as it does with no default branch to measure against; that case fires this note. A branch with no commits of its own (a fresh `git switch -c`, one behind the default branch that never diverged and was merely caught up to it — `merge --ff-only`, `pull`, `reset --hard`, `branch -f` onto it — or a detached `HEAD` at the default branch's tip) reads the same empty merge-base for an unrelated reason — there is nothing to name a base for — and `--since <base>` would change nothing, so it stays silent. The two are told apart by the current branch's own reflog: a branch fires only once its *own* commit put its tip where it is (``GitContext/hasCommitsOfItsOwn(_:)``), which the fast-forward case above has and a branch merely moved onto the default branch's history — by any of those catch-up mechanisms — never does, whether or not it once had commits of its own that the move discarded.
    public static func noBranchRangeNote(since: String?, in workingDirectory: URL) -> String? {
        guard since == nil else {
            return nil
        }
        guard let root = GitContext.discoverRoot(from: workingDirectory) else {
            return nil
        }
        let git = GitContext(repoRoot: root)
        guard let head = try? git.head(), let defaultBranch = git.defaultBranch() else {
            return nil
        }
        guard let currentBranch = git.currentBranch(), currentBranch != defaultBranch.name else {
            return nil
        }
        guard git.mergeBase(defaultBranch.ref, head) == head, git.hasCommitsOfItsOwn(currentBranch) == true else {
            return nil
        }
        return "no branch range was found — its merge-base with \(defaultBranch.name) is HEAD; name the base with --since <base>"
    }

    /// The functions one file's two sides show written, as bare identifiers — any Swift file's, not only one that reads as a test source.
    ///
    /// A function the change adds or edits is a test it wrote, and so is every function nested under a container it added whole — a new suite file adds all of its tests, and the declaration diff reports the container as one entry. A `.moved` declaration is not: its text is what it was, so it is an untouched test that was merely reordered.
    ///
    /// **No file is passed over for how it imports.** An import is spelled more ways than a pattern keeps up with — an attribute before it, an access level, one declaration named out of the module — and a test file passed over for one is a written test folded away as untouched: a false green. A function that is no test at all can only keep a line listed, which is the safe way to be wrong.
    static func identifiers(inTestSource path: String, bytes: (old: Data?, new: Data?)) -> Set<String> {
        let status: FileDiff.Status = if bytes.old == nil {
            .added
        } else if bytes.new == nil {
            .deleted
        } else {
            .modified
        }
        let diff = FileDiff.compare(path: path, status: status, lineStat: nil, bytes: bytes)
        var found: Set<String> = []
        for change in diff.changes {
            if change.symbolKind == .function, change.kind == .added || change.kind == .changed {
                found.insert(RunWithoutAnswer.identifier(of: change.name))
            }
            if change.kind == .added {
                found.formUnion(change.nestedFunctions.map { RunWithoutAnswer.identifier(of: $0.name) })
            }
        }
        // A name that reduces to nothing matches nothing, and would fold a test rather than list it.
        found.remove("")
        return found
    }
}

private extension ChangedTests {
    /// One file the change touched: the path its before side is read at, and where its after side comes from.
    struct Touched {
        let before: String
        let after: After
    }
}

extension ChangedTests.Touched {
    /// Where a touched file's after side is read from.
    enum After {
        /// Deleted: there is no after side.
        case gone
        /// As `HEAD` holds it.
        case committed
        /// As the working tree holds it.
        case disk
    }
}

private extension GitContext.Change {
    /// The path this file had before the change: where a rename took it from, and otherwise its own.
    var origin: String {
        if case let .renamed(from) = kind {
            from
        } else {
            path
        }
    }

    /// Whether the change took this file out of the tree, leaving no after side to read.
    var isDeletion: Bool {
        if case .deleted = kind {
            true
        } else {
            false
        }
    }
}
