//
// Copyright © Agulhas Labs
//

import Foundation

/// The repo's git state, read fresh per query: HEAD, the dirty set, the git-visible file list, and range diffs.
///
/// Query-time `git status` is the invalidation source of truth — it cannot be "missed" the way a hook can, and it costs ~20ms (Docs/Design.md §2). All path-emitting commands run with `-z` (NUL-terminated), because git's default C-style quoting of non-ASCII paths would otherwise corrupt every path containing them.
///
/// **Every read leaves the caller's index exactly as it found it** — see ``runData(arguments:in:input:)``. Other sessions work in the same checkout, and a read that takes `index.lock` for an instant is one that makes their `git add` or `git commit` fail.
public struct GitContext {
    public let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    /// Resolves the enclosing repository root for any directory, or `nil` outside a work tree — through the ``RootDiscovery`` bound for the current scope where one is.
    public static func discoverRoot(from directory: URL) -> URL? {
        guard let bound = RootDiscovery.current else { return spawnedRoot(from: directory) }
        return bound.root(from: directory)
    }

    /// The root `git rev-parse --show-toplevel` names for `directory`, asked afresh.
    public static func spawnedRoot(from directory: URL) -> URL? {
        guard let output = try? run(arguments: ["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The current HEAD commit, or `nil` on an unborn branch (fresh repo, no commits yet).
    public func head() throws -> String? {
        guard let output = try? Self.run(arguments: ["rev-parse", "--verify", "HEAD"], in: repoRoot) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every `.swift` path git can see — tracked plus untracked-unignored — honouring all ignore rules.
    ///
    /// This is the enumeration source of truth: gitignored files are consistently *outside* the tool, because the invalidation layer (status/diff) could never see their changes anyway.
    public func visibleSwiftFiles() throws -> [String] {
        let output = try Self.run(
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.swift"],
            in: repoRoot, within: ChildDeadline.gitBulk
        )
        return output.split(separator: "\0").map(String.init)
    }

    /// Whether git's ignore rules keep an untracked repo-relative path out of ``visibleSwiftFiles()`` — `false` for a tracked file whatever the rules say, since the listing carries every tracked file, and `false` when git cannot answer.
    public func ignores(relativePath: String) -> Bool {
        // `check-ignore -q` exits 0 for an ignored path and nonzero otherwise, and `run` throws on nonzero.
        (try? Self.run(arguments: ["check-ignore", "-q", "--", Self.literalPathspec(relativePath)], in: repoRoot)) != nil
    }

    /// `path`, made safe to pass to a git command that reads its paths as pathspecs.
    ///
    /// `--` alone does not turn pathspec magic off, so a leading `:` (as `git check-ignore` reads it, `--stdin` included) is read as the start of a `:(...)` magic signature rather than a literal colon. `--literal-pathspecs` is not an option: `check-ignore` refuses it outright ("pathspec magic not supported by this command: 'literal'", checked live). Prefixing `./` instead is read identically by git and leaves the path resolving to the same file, so a caller mapping git's answer back to `path` need only strip that prefix off again.
    private static func literalPathspec(_ path: String) -> String {
        path.hasPrefix(":") ? "./\(path)" : path
    }

    /// The last pattern in the `.gitignore` files at or below `directory` matching each of `paths`, relative to it, or one of its parent directories, matched case-sensitively — empty where none does, and `nil` where git cannot say.
    ///
    /// `directory` is read as the root of a tree of its own, inside a repository or not: no `.gitignore` above it, no `.git/info/exclude` and no excludes file git's configuration names is read, which is how `ugrep --ignore-files` reads a directory it is asked to search. git is pointed at an empty repository made for the one call, with `directory` as its working tree, and the repository is removed once it answers.
    ///
    /// A negated pattern comes back with its `!`: the path it matches is kept, not ignored. Case folding is off whatever `core.ignorecase` says, so `gen.swift` matches `gen.swift` alone. All of them in one `check-ignore` process, which exits 1 where no path is ignored.
    public static func lastMatchingIgnorePatterns(_ paths: [String], in directory: URL) -> [String: String]? {
        guard let empty = try? EmptyRepository() else { return nil }
        defer { empty.remove() }
        // A path starting with `:` goes to git disguised (see ``literalPathspec(_:)``); `original` maps each disguised path git echoes back to the path the caller asked about.
        let disguised = paths.map(literalPathspec)
        let original = Dictionary(zip(disguised, paths), uniquingKeysWith: { first, _ in first })
        let input = Data(disguised.map { $0 + "\0" }.joined().utf8)
        let arguments = [
            "--git-dir=\(empty.url.path)", "--work-tree=\(directory.path)",
            "-c", "core.ignorecase=false", "-c", "core.excludesfile=\(empty.url.appendingPathComponent("none").path)",
            "check-ignore", "--no-index", "--verbose", "--non-matching", "-z", "--stdin",
        ]
        guard let output = try? runData(arguments: arguments, in: directory, input: input, succeedingOn: [0, 1], within: ChildDeadline.gitBulk) else { return nil }
        // Four fields a path: the pattern's source, its line and the pattern, all empty where none matches, then the path.
        // A negated pattern is printed with its `!`; a literal `!` escaped in the file keeps its backslash, so never opens on one.
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map { String(bytes: $0, encoding: .utf8) ?? "" }
        var patterns: [String: String] = [:]
        var index = 0
        while index + 3 < fields.count {
            patterns[original[fields[index + 3]] ?? fields[index + 3]] = fields[index + 2]
            index += 4
        }
        return paths.allSatisfy { patterns[$0] != nil } ? patterns : nil
    }

    /// Every directory git's ignore rules keep out of the tree, repo-relative and without a trailing slash, each named at its topmost ignored level — git does not descend into one it has already found ignored.
    func ignoredDirectories() throws -> [String] {
        let output = try Self.run(
            arguments: ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
            in: repoRoot, within: ChildDeadline.gitBulk
        )
        return output.split(separator: "\0").filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
    }

    /// Every string catalog git can see — `.xcstrings` plus legacy `.strings` — honouring all ignore rules, same contract as `visibleSwiftFiles`.
    public func visibleStringCatalogs() throws -> [String] {
        let output = try Self.run(
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.xcstrings", "*.strings"],
            in: repoRoot, within: ChildDeadline.gitBulk
        )
        return output.split(separator: "\0").map(String.init)
    }

    /// The working tree's complete dirty set for `.swift` files — staged, unstaged, and untracked.
    public func dirtySwiftFiles() throws -> [Change] {
        try dirtyFiles(pathspec: ["*.swift"])
    }

    /// The same dirty set with no path restriction — every file git considers changed, `.swift` or not (`diff`'s non-Swift-files section).
    public func dirtyFiles() throws -> [Change] {
        try dirtyFiles(pathspec: [])
    }

    private func dirtyFiles(pathspec: [String]) throws -> [Change] {
        let output = try Self.run(
            arguments: ["status", "--porcelain", "-z", "-uall"] + (pathspec.isEmpty ? [] : ["--"] + pathspec),
            in: repoRoot, within: ChildDeadline.gitBulk
        )
        var changes: [Change] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let entry = tokens[index]
            index += 1
            guard entry.count > 3 else { continue }
            let statusField = String(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if statusField.contains("R") || statusField.contains("C") {
                // -z rename and copy entries carry the ORIGINAL path as the following token (new name is in the entry).
                guard index < tokens.count else { break }
                let original = tokens[index]
                index += 1
                // A copy leaves its source where it was, so only the new path changed; read as a rename, the
                // source's rows would be dropped and the ledger would record a file that is still on disk.
                let kind: Change.Kind = statusField.contains("R") ? .renamed(from: original) : .addedOrModified
                changes.append(Change(kind: kind, path: path))
            } else if statusField.contains("D") {
                changes.append(Change(kind: .deleted, path: path))
            } else {
                changes.append(Change(kind: .addedOrModified, path: path))
            }
        }
        return changes
    }

    /// `.swift` changes between two commits, with statuses (A/M/D/R, and C as the copy it is) honoured — never `--name-only` (Docs/Design.md §6.2).
    public func changedSwiftFiles(from oldHead: String, to newHead: String) throws -> [Change] {
        try changedFiles(from: oldHead, to: newHead, pathspec: ["*.swift"])
    }

    /// The same range diff with no path restriction — every file that differs, `.swift` or not (`diff`'s non-Swift-files section).
    public func changedFiles(from oldHead: String, to newHead: String) throws -> [Change] {
        try changedFiles(from: oldHead, to: newHead, pathspec: [])
    }

    private func changedFiles(from oldHead: String, to newHead: String, pathspec: [String]) throws -> [Change] {
        let output = try Self.run(
            arguments: ["diff", "--name-status", "-z", oldHead, newHead] + (pathspec.isEmpty ? [] : ["--"] + pathspec),
            in: repoRoot, within: ChildDeadline.gitBulk
        )
        var changes: [Change] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard index < tokens.count else { break }
            if status.hasPrefix("R") || status.hasPrefix("C") {
                // diff -z rename and copy order is OLD path first, then NEW.
                let old = tokens[index]
                index += 1
                guard index < tokens.count else { break }
                let new = tokens[index]
                index += 1
                // A copy's source survives it — see `dirtySwiftFiles`.
                changes.append(Change(kind: status.hasPrefix("R") ? .renamed(from: old) : .addedOrModified, path: new))
            } else {
                let path = tokens[index]
                index += 1
                if status == "D" {
                    changes.append(Change(kind: .deleted, path: path))
                } else {
                    changes.append(Change(kind: .addedOrModified, path: path))
                }
            }
        }
        return changes
    }

    /// The git object every repository defines for "nothing" — diffing a root commit (no parent to name) against this reads as every path in it having been added, the same trick `git diff --root` relies on internally.
    public static var emptyTreeHash: String {
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    }

    /// Whether `rev` resolves to a commit in this repository — `diff` uses this to fall back to ``emptyTreeHash`` when a single commit it was given has no parent to name.
    public func resolvesToCommit(_ rev: String) -> Bool {
        // Same throw-on-nonzero-exit contract as `ignores(relativePath:)` above.
        (try? Self.run(arguments: ["rev-parse", "--verify", "--quiet", rev + "^{commit}"], in: repoRoot)) != nil
    }

    /// `rev`, or ``emptyTreeHash`` where `rev` names no commit — the one way that happens for `HEAD` is a branch with nothing committed to it yet, so every git call the working-tree diff makes in `HEAD`'s name reads that empty repository as having nothing, and everything present in the working tree as added, the same substitution a root commit's absent parent already gets.
    public func revisionOrEmptyTree(_ rev: String) -> String {
        resolvesToCommit(rev) ? rev : Self.emptyTreeHash
    }

    /// Every file path in `rev`'s tree, repo-relative whatever the working directory — what `digest --at` and `where --at` read a past revision from; throws git's own refusal when `rev` names no tree.
    public func trackedPaths(at rev: String) throws -> [String] {
        let output = try Self.run(arguments: ["ls-tree", "-r", "-z", "--full-tree", "--name-only", rev], in: repoRoot, within: ChildDeadline.gitBulk)
        return output.split(separator: "\0").map(String.init)
    }

    /// Every file path in `rev`'s tree, and the ones among them that tree records as symbolic links (mode `120000`).
    ///
    /// A revision's answer tests a path against this mode rather than the working tree's, where the same path may be a link today and a file then, or the reverse.
    public func trackedEntries(at rev: String) throws -> (paths: [String], links: Set<String>) {
        let output = try Self.run(arguments: ["ls-tree", "-r", "-z", "--full-tree", rev], in: repoRoot, within: ChildDeadline.gitBulk)
        var paths: [String] = []
        var links: Set<String> = []
        for record in output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let path = String(record[record.index(after: tab)...])
            paths.append(path)
            if record.hasPrefix("120000 ") {
                links.insert(path)
            }
        }
        return (paths, links)
    }

    /// The full hash of the commit `rev` names, or `nil` when it names none.
    public func commitHash(_ rev: String) -> String? {
        (try? Self.run(arguments: ["rev-parse", "--verify", "--quiet", rev + "^{commit}"], in: repoRoot))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The best common ancestor of two commits — what `A...B` compares `B` against — or `nil` when they share no history.
    public func mergeBase(_ left: String, _ right: String) -> String? {
        guard let output = try? Self.run(arguments: ["merge-base", left, right], in: repoRoot, within: ChildDeadline.gitBulk) else { return nil }
        let hash = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// The current branch's short name, or `nil` on a detached `HEAD` (or an unborn one).
    public func currentBranch() -> String? {
        guard let output = try? Self.run(arguments: ["symbolic-ref", "--short", "-q", "HEAD"], in: repoRoot) else { return nil }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether the named branch's tip is there because *it* committed — as opposed to a fast-forward merge, a pull, a `reset`, or a `branch -f` having moved the ref onto some other history — or `nil` where the reflog cannot answer (disabled, expired, or the ref names nothing).
    ///
    /// Read with `--format=%gs` (git does not translate the subject) and judge only the newest entry — `reflog show` lists newest first, and the newest entry is what put the ref where it is *now*. A commit-type subject (`commit:`, `commit (initial):`, `commit (amend):`, `commit (merge):`, `cherry-pick:`) there means the branch's own history put the tip here, whether or not the default branch has since caught up to it — the fast-forward test below. Anything else — `merge …: Fast-forward`, `pull: Fast-forward`, `reset: moving to …`, `branch: Reset to …`, `branch: Created from …` — means some other ref's history landed here, even where an *earlier* entry on the same ref was a commit: a branch that committed and was then `reset --hard` onto the default branch has lost those commits as far as its current tip is concerned, and reads `false` here. A branch merely sitting behind the default branch, never having diverged from it, reads `false` too — its one "branch: Created from …" entry is not a commit. Only where the reflog itself gives nothing to judge (disabled, expired, or the ref names nothing) does this read `nil`. Judging every entry back to a remote-tracking checkout (rather than only the newest) would need walking past `branch: Created from origin/…`, which is not cheap to resolve reliably in general — that case is left reading `false` here, silent rather than reachable.
    public func hasCommitsOfItsOwn(_ name: String) -> Bool? {
        guard let output = try? Self.run(arguments: ["reflog", "show", "--format=%gs", "refs/heads/\(name)"], in: repoRoot, within: ChildDeadline.gitBulk) else { return nil }
        let entries = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let newest = entries.first else { return nil }
        return Self.commitTypeSubjectPrefixes.contains { newest.hasPrefix($0) }
    }

    private static let commitTypeSubjectPrefixes = [
        "commit:", "commit (initial):", "commit (amend):", "commit (merge):", "cherry-pick:",
    ]

    /// The repository's default branch, and the ref a feature branch should be measured against — for the session-start resumption block's "how far has this moved" line, not for anything a query answer shows.
    ///
    /// Prefers a local branch of that name: no network call, and the same commits every other checkout of this repository has, which a remote-tracking ref updated by someone else's `fetch` is not guaranteed to be. Falls back to `origin/HEAD`'s target for a clone that has never checked the default branch out locally — the common case for a linked worktree, whose branch is never `main` itself.
    public func defaultBranch() -> (name: String, ref: String)? {
        if let symbolic = try? Self.run(arguments: ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: repoRoot) {
            let remoteRef = symbolic.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = remoteRef.firstIndex(of: "/") {
                let name = String(remoteRef[remoteRef.index(after: slash)...])
                return (name, localBranchExists(name) ? name : remoteRef)
            }
        }
        for candidate in ["main", "master"] where localBranchExists(candidate) {
            return (candidate, candidate)
        }
        return nil
    }

    private func localBranchExists(_ name: String) -> Bool {
        (try? Self.run(arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repoRoot)) != nil
    }

    /// How many commits `to` has that `from` lacks — `git rev-list --count from..to`.
    public func commitCount(from: String, to: String) throws -> Int {
        let output = try Self.run(arguments: ["rev-list", "--count", "\(from)..\(to)"], in: repoRoot, within: ChildDeadline.gitBulk)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The committer date `git log` would print for `rev`, or `nil` when it names nothing — used only to tell whether the tree has moved since some earlier moment, never shown as itself.
    ///
    /// `--no-show-signature` because a git config that turns signature checks on for `log` would otherwise print a signed commit's verification ahead of the date, and the date would fail to parse.
    public func commitDate(_ rev: String) -> Date? {
        let arguments = ["log", "-1", "--no-show-signature", "--format=%cI", rev]
        guard let output = try? Self.run(arguments: arguments, in: repoRoot) else { return nil }
        return ISO8601DateFormatter().date(from: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The abbreviated hash git would print for `rev`, or `nil` when it names nothing.
    public func shortHash(_ rev: String) -> String? {
        guard let output = try? Self.run(arguments: ["rev-parse", "--short", "--verify", "--quiet", rev], in: repoRoot) else { return nil }
        let hash = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Where git keeps each of `names` inside its own directories — `git rev-parse --git-path`, one per name, in order — or `nil` when git cannot answer.
    ///
    /// Asked of git rather than built from `.git/…` because a linked worktree keeps some of these privately (`logs/HEAD`) and shares others with every worktree (`logs/refs/stash`), and only git knows which is which. The paths are named whether or not anything exists there yet.
    public func gitPaths(_ names: [String]) -> [URL]? {
        guard !names.isEmpty,
              let output = try? Self.run(arguments: ["rev-parse"] + names.flatMap { ["--git-path", $0] }, in: repoRoot)
        else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == names.count else { return nil }
        return lines.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : repoRoot.appendingPathComponent($0) }
    }

    /// Every untracked file git would show as new — `--others` with no `--cached`, so tracked files are excluded (unlike ``visibleSwiftFiles()``, which wants both).
    public func untrackedFiles() throws -> [String] {
        let output = try Self.run(arguments: ["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot, within: ChildDeadline.gitBulk)
        return output.split(separator: "\0").map(String.init)
    }

    /// The repository's own `url.<base>.insteadof` rewrites, as git configuration keys and values in the order the file lists them — empty when it has none.
    ///
    /// Only the repository's configuration file is read, with the files it includes: the user's and the system's are read by any git wherever it runs, while this one is read only by a git that finds the repository, which a clone made in a build directory of its own does not.
    public func localURLRewrites() -> [(key: String, value: String)] {
        // `--get-regexp` exits 1 when nothing matches, which is the same answer as an empty list. `--local` alone
        // does not follow `include.path`, so `--includes` asks for it.
        let arguments = ["config", "--local", "--includes", "--null", "--get-regexp", #"^url\..*\.insteadof$"#]
        guard let output = try? Self.run(arguments: arguments, in: repoRoot) else {
            return []
        }
        // Each entry is the key, a newline and the value, ended by a NUL; a key with no value has no newline, and rewrites nothing.
        return output.split(separator: "\0").compactMap { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return nil
            }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// Added/removed line counts per path, keyed by the after-side path; `to` omitted compares `rev` against the working tree, the same as bare `git diff <rev>`.
    ///
    /// Renames are detected exactly as the change list detects them (both are plain `git diff`), so a renamed file is counted for what its edit changed rather than as a whole-file add — the rename's own record, `added TAB removed TAB NUL old NUL new NUL` under `-z`, is read for it.
    public func lineStats(from rev: String, to: String? = nil) throws -> [String: LineStat] {
        var arguments = ["diff", "--numstat", "--no-textconv", "-z", rev]
        if let to {
            arguments.append(to)
        }
        let tokens = try Self.run(arguments: arguments, in: repoRoot, within: ChildDeadline.gitBulk).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var stats: [String: LineStat] = [:]
        var index = 0
        while index < tokens.count {
            let fields = tokens[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard fields.count == 3 else { continue }
            var path = String(fields[2])
            if path.isEmpty {
                // A rename: the two paths follow as tokens of their own.
                guard index + 1 < tokens.count else { break }
                path = tokens[index + 1]
                index += 2
            }
            // A binary file prints "-" for both counts rather than a number.
            guard let added = Int(fields[0]), let removed = Int(fields[1]) else {
                stats[path] = LineStat(added: 0, removed: 0, binary: true)
                continue
            }
            stats[path] = LineStat(added: added, removed: removed, binary: false)
        }
        return stats
    }

    /// The byte size of the raw, human-facing `git diff` for this same comparison — the baseline `diff` prices its own answer against.
    ///
    /// Counted as bytes, never decoded first (a diff of a file in another encoding is still bytes a reader is sent), and with `--no-ext-diff`, since a configured external diff tool is a program to launch, not a size to measure.
    public func diffByteCount(from rev: String, to: String? = nil) throws -> Int {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", rev]
        if let to {
            arguments.append(to)
        }
        return try Self.runData(arguments: arguments, in: repoRoot, within: ChildDeadline.gitBulk).count
    }

    /// Many blobs in one process: each `(rev, path)` read through `git cat-file --batch`, in order, `nil` where the path does not exist at that revision (or is not a file there).
    ///
    /// One process per range rather than one `git show` per file per side — a range of a few hundred files otherwise spends most of its time starting git. A path git cannot carry on one line of the batch protocol (one holding a newline) is read with `git show` instead.
    public func blobs(_ requests: [(rev: String, path: String)]) throws -> [Data?] {
        let batchable = requests.enumerated().filter { !$0.element.path.contains("\n") && !$0.element.rev.contains("\n") }
        var results = [Data?](repeating: nil, count: requests.count)
        if !batchable.isEmpty {
            let input = Data(batchable.map { "\($0.element.rev):\($0.element.path)\n" }.joined().utf8)
            let output = try Self.runData(arguments: ["cat-file", "--batch"], in: repoRoot, input: input, within: ChildDeadline.gitBulk)
            var reader = BatchReader(output: output)
            for (offset, _) in batchable {
                results[offset] = try reader.next()
            }
        }
        for (offset, request) in requests.enumerated() where request.path.contains("\n") || request.rev.contains("\n") {
            results[offset] = try? Self.runData(arguments: ["show", "--no-textconv", "\(request.rev):\(request.path)"], in: repoRoot, within: ChildDeadline.gitBulk)
        }
        return results
    }

    /// `.swift` paths whose deletion is staged — a `git rm`, or a delete added with the rest of a change.
    ///
    /// Gone from what git would commit, and so from ``visibleSwiftFiles()`` too, which lists only what git still tracks. `--no-renames` because a staged rename is a deletion of its source as far as a store that compiled the source is concerned, and rename detection would report it as something else.
    func stagedSwiftDeletions() throws -> [String] {
        try Self.run(
            arguments: ["diff", "--cached", "--no-renames", "--diff-filter=D", "--name-only", "-z", "--", "*.swift"],
            in: repoRoot, within: ChildDeadline.gitBulk
        ).split(separator: "\0").map(String.init)
    }

    /// `.swift` paths deleted by a commit reachable from HEAD and dated at or after `date`, renamed-away sources included.
    ///
    /// `--no-renames` for the reason ``stagedSwiftDeletions()`` gives. Empty on an unborn branch, which has no commits to list.
    ///
    /// The date is given to git as `@<seconds> +0000`: only with a zone after it does git read `@<seconds>` as seconds since 1970 whatever their count. A count of eight digits or fewer without one is read as a loose date instead — `@1` as the first of this month at the current time of day.
    ///
    /// Judged by the commit's date, not by when it reached this tree. A merge commit is read as its diff against its first parent — `git log` lists no files for a merge otherwise — so a merge made since `date` names every deletion it brought in, however long before the deletion itself was committed. A fast-forward makes no commit of its own, so older work brought in that way is not listed.
    func swiftFilesDeletedInCommits(since date: Date) throws -> [String] {
        guard try head() != nil else { return [] }
        return try Self.run(
            arguments: [
                "log", "--since=@\(Int(date.timeIntervalSince1970)) +0000", "--diff-merges=first-parent", "--no-renames",
                "--diff-filter=D", "--name-only", "--format=", "-z", "--", "*.swift",
            ],
            in: repoRoot, within: ChildDeadline.gitBulk
        ).split(separator: "\0").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
    }

    /// The git directory a repository shares with every worktree linked to it — the identity two roots must match on to be the same repository.
    ///
    /// `rev-parse --git-common-dir` answers relative to the working tree it is run in (`.git` in a checkout, an absolute path in a linked worktree), so the result is resolved against `root` before being returned. Symlinks are resolved too: two spellings of one path must not read as two repositories.
    public static func commonDirectory(of root: URL) -> URL? {
        directories(of: root)?.common
    }

    /// The two git directories a working tree answers with: the one that is private to it, and the one it shares with every worktree of the repository.
    ///
    /// **Equal means this is the repository's main working tree; different means it is a linked one.** That is the only test that holds for every layout git supports, and path arithmetic does not: deriving the checkout as the common directory's *parent* is right for `<checkout>/.git` and wrong for both a bare repository (`repo.git` sits beside its worktrees, not inside a checkout) and a `--separate-git-dir` tree (whose git directory may be anywhere at all). Both spellings would answer with the name of whatever directory happened to contain the git directory.
    ///
    /// One `rev-parse` for the pair rather than two, because the pair is the answer and either half alone is not — `rev-parse` prints its options in the order they are given. Each path is resolved against `root` (git answers relatively inside a checkout) and through symlinks, so two spellings of one path never read as two repositories.
    public static func directories(of root: URL) -> (own: URL, common: URL)? {
        guard let output = try? run(arguments: ["rev-parse", "--git-dir", "--git-common-dir"], in: root) else {
            return nil
        }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return (resolve(lines[0], against: root), resolve(lines[1], against: root))
    }

    /// A path git printed, made absolute against the tree it was printed for and reduced to one spelling.
    ///
    /// This is where the pair's canonicalisation lives, which is why callers compare the two URLs with `==` and not through ``CanonicalPath``. The guideline that sends comparisons through `CanonicalPath.of` is about paths that were *recorded* — a log line, a registry entry — where normalising on the way in would rewrite history. These are not recorded anywhere: they are read from git and compared inside the same call, so canonicalising at the boundary and comparing plainly is the same operation with one fewer place to forget it. `resolvingSymlinksInPath` is the half that matters — `/tmp/x` and `/private/tmp/x` are one repository — and it is exactly what `CanonicalPath.of` would apply.
    private static func resolve(_ path: String, against root: URL) -> URL {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Appends the cache directory to the *common* `.git/info/exclude` once — ignore coverage without touching a committed file, and correct in linked worktrees (per-worktree gitdirs have no `info/`).
    public func ensureCacheExcluded() {
        ensureCacheExcluded(inCommonDirectory: Self.commonDirectory(of: repoRoot))
    }

    /// The same append, into a common directory the caller already asked git for.
    ///
    /// Opening an engine needs both git directories to name its tree, and asking `rev-parse` for them a second time here was one more git process on every command's fixed cost; `nil` is git's own "no answer", as it is for the plain form.
    public func ensureCacheExcluded(inCommonDirectory commonDirectory: URL?) {
        guard let commonDirURL = commonDirectory else { return }
        let excludeURL = commonDirURL.appendingPathComponent("info/exclude")
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let entry = "\(SiftPaths.directoryName)/"
        guard !existing.contains(entry) else { return }

        let separator = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
        let updated = existing + separator + entry + "\n"
        try? FileManager.default.createDirectory(at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    /// Every read this type makes, run in `directory` and with **no repository in its environment** (``ProcessEnvironment/withoutGit(from:)``) — a `GIT_DIR` inherited from a caller running under a git hook would otherwise answer about the hook's repository instead of this one.
    ///
    @discardableResult
    static func run(arguments: [String], in directory: URL, within bound: TimeInterval = ChildDeadline.git) throws -> String {
        try String(data: runData(arguments: arguments, in: directory, within: bound), encoding: .utf8) ?? ""
    }

    /// No repository (``ProcessEnvironment/withoutGit(from:)``) and `GIT_OPTIONAL_LOCKS=0`, so a read never takes `index.lock` to write a stat-cache refresh back.
    static func readEnvironment() -> [String: String] {
        var environment = ProcessEnvironment.withoutGit()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// **Bounded by `bound`, ``ChildDeadline/git`` unless the caller says otherwise; a read whose cost grows with the repository or with its input (a listing, a status, a diff, a history walk, a blob, a batch of paths) says ``ChildDeadline/gitBulk``.** A git that has not answered by then is sent `SIGTERM`, then `SIGKILL`, with every process still in its group, and reaped; reading stops whatever still holds its pipes, and the call fails as any failed git does: a repository git cannot read (a config `include.path` naming a FIFO, say) would otherwise hang the call for good.
    ///
    /// The same, returning stdout's bytes undecoded, with `input` (when given) written to the child's stdin, and failing on any exit status it is not told to take as success.
    ///
    /// **No read writes the index**, which two of git's reads otherwise do behind the caller's back. `git status` refreshes the index's stat cache and, when it can take `index.lock`, writes it back; `GIT_OPTIONAL_LOCKS=0` — the one `GIT_` key put back into the scrubbed environment — turns that off. A porcelain `git diff` against the working tree (``lineStats(from:to:)``, ``diffByteCount(from:to:)``) does the same through `refresh_index_quietly`, which ignores that variable; `diff.autoRefreshIndex=false` turns it off instead, and costs those two nothing in accuracy: a file whose stat changed and content did not is compared by content and still prints no count and no byte. It is not free for every diff — a `--name-only` or `--name-status` diff against the working tree cannot look at content and lists that file, which is why a list of changed working-tree paths comes from `status` (``dirtyFiles()``). The setting means nothing to any other command, so it rides on every one — a diff added later cannot forget it.
    static func runData(arguments: [String], in directory: URL, input: Data? = nil, succeedingOn: Set<Int32> = [0], within bound: TimeInterval = ChildDeadline.git) throws -> Data {
        // A working directory `Process` cannot enter — one spelled `/..` from a transcript's relative
        // worktree path, or one gone since the transcript named it — would make it raise an Objective-C
        // exception nothing here can catch, taking the whole command down; the path is standardised first
        // and anything that is still not a directory is answered as a failed git call, which every caller
        // already treats as "no repository".
        let directory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed: \(directory.path) is not a directory")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "diff.autoRefreshIndex=false"] + ProcessEnvironment.gitHardening + arguments
        process.currentDirectoryURL = directory
        process.environment = readEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Input goes in on a pipe, written from its own thread: `cat-file --batch` answers each request
        // as it reads it, so the write and the drain below run concurrently and neither buffer can stall
        // the other. `F_SETNOSIGPIPE` turns a child that exits before reading all of it into a write
        // error rather than a SIGPIPE that would take this process down mid-write. Nothing touches disk,
        // so a process cut off before the deadline (the session-start gather's 1.5s bound) leaves nothing
        // behind.
        let stdin = Pipe()
        if input != nil {
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = stdin
        }
        // Exit is awaited on the termination handler rather than `waitUntilExit`, which, when the child has
        // not been reaped by the time it is called, sleeps in a run loop for about 65 ms after a git call
        // that took 10 — the larger part of every working-tree command's fixed cost.
        let exited = DispatchSemaphore(value: 0)
        let watch = ChildDeadline.Watch(process, within: bound)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            ProcessStreams.abandon(stdout, stderr, stdin)
            throw error
        }
        watch.arm()
        if let input {
            let writer = Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            writer.name = "sift.git.stdin"
            writer.start()
        }
        // Both streams at once — `git ls-files` on a monorepo and a refusal's eighty lines of usage
        // advice are each capable of filling a 64 KB pipe, and reading one to the end first is how
        // that becomes a hang rather than an answer. See `ProcessStreams.drain`. Reading stops at the
        // deadline, whatever descendant of git still holds the pipes.
        guard let (data, errorData) = watch.collect(stdout: stdout, stderr: stderr, exited: exited) else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed: no answer in \(Int(bound)) seconds")
        }
        guard succeedingOn.contains(process.terminationStatus) else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed: \(detail)", detail: detail)
        }
        return data
    }
}

private extension GitContext {
    /// Reads `git cat-file --batch` output one answer at a time: `<oid> <type> <size>` then the bytes, or `<name> missing`.
    struct BatchReader {
        let output: Data
        var offset: Int

        init(output: Data) {
            self.output = output
            offset = output.startIndex
        }

        /// The next answer's bytes, `nil` for a name that resolves to nothing or to something that is not a file.
        mutating func next() throws -> Data? {
            guard let newline = output[offset...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw GitError(message: "git cat-file --batch ended before every request was answered")
            }
            let header = String(bytes: output[offset ..< newline], encoding: .utf8) ?? ""
            offset = newline + 1
            let fields = header.split(separator: " ")
            guard fields.count == 3, let size = Int(fields[2]) else {
                // `missing`, `ambiguous`: a header with no body to skip.
                return nil
            }
            let end = offset + size
            guard end <= output.endIndex else {
                throw GitError(message: "git cat-file --batch answered with fewer bytes than it announced")
            }
            let body = output[offset ..< end]
            offset = min(end + 1, output.endIndex)
            return fields[1] == "blob" ? Data(body) : nil
        }
    }
}

public extension GitContext {
    /// One entry of the dirty set or a range diff.
    struct Change: Sendable {
        public let kind: Kind
        public let path: String
    }
}

public extension GitContext.Change {
    /// How the file changed — the index's response differs per status (Docs/Design.md §6.2).
    enum Kind: Sendable {
        case addedOrModified
        case deleted
        case renamed(from: String)
    }
}

public extension GitContext {
    /// Added/removed line counts for one path, from `--numstat`.
    struct LineStat: Sendable, Equatable {
        public let added: Int
        public let removed: Int
        public let binary: Bool
    }
}
