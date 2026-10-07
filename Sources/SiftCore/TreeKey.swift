//
// Copyright © Agulhas Labs
//

import Foundation

/// The identity of what a command ran *on*: the content of the working tree, not the commit it sits at.
///
/// A commit hash is the wrong key for a proved run. Rewording a message, rebasing, or committing a change already present in the working tree all move `HEAD` while the bytes a compiler reads stay identical, and — the direction that matters — a tree can be edited without `HEAD` moving at all. Only content can say whether two runs ran the same code.
///
/// **Git's own object identity is the key, computed over a scratch index.** The enumeration is git's: everything tracked, at its working-tree content rather than at what happens to be staged, plus everything untracked that the ignore rules do not exclude — the same population `reconcile` walks (Docs/Design.md §6.4), and the same one the privacy gate reads. A scratch index seeded from the repository's own is what makes it cheap: git keeps the stat cache in the index, so a tree whose files have not been touched re-hashes nothing, and the caller's index is never written to.
///
/// **What it covers is exactly what git can see, and nothing else.** A gitignored build directory, the tool's own state, the environment and the machine are all outside it by construction — which is why every consumer of this key pairs it with a bound that expires, rather than treating a match as proof on its own.
public struct TreeKey: Sendable, Equatable {
    /// The git tree object the working tree's visible content hashes to.
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public extension TreeKey {
    /// How much of the key an answer prints, since the full object name identifies nothing a reader can act on.
    static let displayLength = 12

    /// The abbreviation an answer carries — long enough to be recognisable between two answers in one session, never presented as the whole name.
    var displayValue: String {
        String(value.prefix(Self.displayLength))
    }

    /// The key for the working tree at `repositoryRoot`, or `nil` when git will not answer.
    ///
    /// Every failure here is a refusal rather than a guess: a key that could not be computed means no run may be recorded against this tree and no recorded run may be trusted for it, which is the safe direction in both cases.
    ///
    /// The scratch index lives in the tool's own cache directory, which is gitignored, so `git add` never sees it and it dies with the checkout. It carries a random token because parallel runs in one repository are the assumed norm, and it is removed however this returns — git's lock file for it sits beside it, out of reach of the caller's own index lock.
    static func of(repositoryRoot: URL) -> TreeKey? {
        guard let gitDirectories = GitContext.directories(of: repositoryRoot) else {
            return nil
        }
        let cache = SiftPaths.cache(in: repositoryRoot)
        guard (try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let scratch = cache.appendingPathComponent("tree-index-\(String(format: "%08x", UInt32.random(in: 0 ... .max)))")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: scratch.path + ".lock"))
        }
        // A copy, never the repository's own index: `git add` writes the index it is given, and handing it
        // the caller's would stage their whole working tree behind their back. The copy failing is not a
        // failure — a repository with no index yet is one git will build from scratch here, more slowly.
        try? FileManager.default.copyItem(at: gitDirectories.own.appendingPathComponent("index"), to: scratch)
        // The cache directory is put out of git's view first, by the same mechanism the indexer uses. It is
        // this tool's own state and outside the key by definition — and a tree where it is neither gitignored
        // nor excluded yet would hash the scratch index this very call is writing, giving a key that never
        // equals itself twice. It is done through the ignore rules rather than through a `:(exclude)`
        // pathspec, which `git add` reads as naming an ignored path outright and refuses the whole command for.
        GitContext(repoRoot: repositoryRoot).ensureCacheExcluded(inCommonDirectory: gitDirectories.common)
        guard hidesNothing(in: repositoryRoot, index: scratch) else {
            return nil
        }
        guard (try? run(["add", "--all"], in: repositoryRoot, index: scratch, within: ChildDeadline.gitBulk)) != nil,
              let written = try? run(["write-tree"], in: repositoryRoot, index: scratch, within: ChildDeadline.gitBulk)
        else {
            return nil
        }
        let value = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : TreeKey(value: value)
    }

    /// The repository-relative paths whose content differs between `earlier` and this key, or `nil` when git cannot compare the two.
    ///
    /// Both keys are tree objects `write-tree` put in the repository's object store, which every worktree shares, so a key recorded in one worktree compares against one taken in another. `nil` is a tree git no longer holds — pruned since, or recorded against another repository's store — and is said as *unknown*, never as *nothing changed*.
    func changedPaths(since earlier: TreeKey, repositoryRoot: URL) -> [String]? {
        guard let listed = try? Self.run(["diff-tree", "-r", "--name-only", "-z", earlier.value, value], in: repositoryRoot, index: nil, within: ChildDeadline.gitBulk) else {
            return nil
        }
        return listed.split(separator: "\0").map(String.init)
    }

    /// Whether `earlier` is this tree with nothing changed but files a compiler or the package resolver never reads, so a green run of `earlier` stands for this one too.
    ///
    /// What counts as read is a Swift source (`.swift`, which holds `Package.swift` as well), a `Package.resolved` and an Xcode project file; a note, a changelog or any other file whose bytes moved is outside it. A tree the object store no longer holds is *unknown*, which is a no.
    func sameSwiftSources(as earlier: TreeKey, repositoryRoot: URL) -> Bool {
        guard let changed = changedPaths(since: earlier, repositoryRoot: repositoryRoot) else { return false }
        return !changed.contains(where: Self.isBuildInput)
    }

    private static func isBuildInput(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".swift") || name == "Package.resolved" || name == "project.pbxproj"
    }

    /// Whether the index hides no entry from the working tree — no `assume-unchanged` bit, no `skip-worktree`.
    ///
    /// Both tell git to trust the index over the file and stop stat-ing it, so `git add --all` walks straight past an entry carrying one and the key comes back identical over an edited tree. Every other thing this key cannot see is outside git by construction and changes only by a deliberate act, which is what the bound on a record's age covers; this is the one that is set once and then silently applies to every run afterwards, for as long as the bit is set. An hour does not bound that, so it is refused instead.
    ///
    /// Read off the scratch index, which is where the bits the walk would honour actually are: a copy carries the caller's, and a repository whose index could not be copied has none to carry.
    private static func hidesNothing(in directory: URL, index: URL) -> Bool {
        guard let listed = try? run(["ls-files", "-v"], in: directory, index: index, within: ChildDeadline.gitBulk) else {
            return false
        }
        // `ls-files -v` tags each path with a letter: lowercase for an entry marked assume-unchanged, `S` for
        // one marked skip-worktree. Anything else is an entry git will stat, which is the whole requirement.
        return !listed.split(separator: "\n").contains { line in
            guard let tag = line.first else { return false }
            return tag.isLowercase || tag == "S"
        }
    }

    /// One `git`, bounded by `bound` (``ChildDeadline/git`` unless the caller says otherwise; the reads that walk the whole tree say ``ChildDeadline/gitBulk``), run in the tree and pointed at the scratch index where there is one.
    ///
    /// The environment is scrubbed of git's own variables first, for the reason every other git this tool spawns is (``ProcessEnvironment/withoutGit(from:)``): this runs under a `pre-push` hook, which exports `GIT_DIR` and `GIT_INDEX_FILE` into it, and an inherited pair would point these commands at the hook's repository and at the caller's real index. `GIT_INDEX_FILE` then goes back in as the one variable this needs, naming the scratch copy; a command that reads only objects is given none.
    @discardableResult
    private static func run(_ arguments: [String], in directory: URL, index: URL?, within bound: TimeInterval = ChildDeadline.git) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ProcessEnvironment.gitHardening + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessEnvironment.withoutGit()
        environment["GIT_INDEX_FILE"] = index?.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Exit is awaited on the termination handler, as every git read in `GitContext` is: `waitUntilExit`
        // sleeps in a run loop for about 65 ms whenever the child has not been reaped by the time it is
        // called, and a green build takes two keys of four git calls each.
        let exited = DispatchSemaphore(value: 0)
        let watch = ChildDeadline.Watch(process, within: bound)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            ProcessStreams.abandon(stdout, stderr)
            throw error
        }
        watch.arm()
        guard let (data, errorData) = watch.collect(stdout: stdout, stderr: stderr, exited: exited) else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed: no answer in \(Int(bound)) seconds")
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
