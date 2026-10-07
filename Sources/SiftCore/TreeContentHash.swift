//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// The content a run started on, hashed without writing anything: what `flakes` keys a test's outcomes by.
///
/// **Content, because neither `HEAD` nor "dirty or not" separates a deliberate red from a flake.** A fix is usually uncommitted, so `HEAD` alone files a failing run and its fix under one key; and a set-aside and its fix are both dirty. A deliberate red changes bytes and a genuine flake does not, so a test that failed and passed under one of these values failed and passed on the same bytes.
///
/// **SHA-256 over three parts, each hashed on its own and the three hashed together:** the commit `HEAD` names, the bytes of `git diff-index -p --binary HEAD`, and every untracked, unignored path beside its `git hash-object --no-filters`. The parts are hashed separately so no byte of one can be read as a byte of the next.
///
/// **Read-only, unlike ``TreeKey``.** That key writes blobs and a tree object through a scratch index; this one runs `rev-parse`, `ls-files`, `diff-index` and `hash-object` without `-w`, with optional locks off, so it touches no object store and no index — a cost every test run pays has to leave nothing behind it. The diff is the plumbing `diff-index` rather than porcelain `git diff`, because porcelain refreshes the index whenever a file's stat has moved and its bytes have not, and optional locks off does not stop it: that write takes `index.lock` under a parallel session's `git commit`. Plumbing prints nothing for such a file, so a `touch` changes neither the index nor the hash.
///
/// **Bounded, and every bound refuses rather than truncates.** A truncated hash equates two trees that differ past the cut, which is the one error this value exists to prevent, so a tree past a bound records no hash and its runs are counted as unknown. The same goes for an index entry git has been told not to stat, which would let an edit hide from the diff; a submodule with uncommitted content or an untracked nested repository, whose bytes no diff of this repository carries; any git failure; and git not answering within ``budget``.
public struct TreeContentHash {
    /// The most `git diff-index -p --binary HEAD` output hashed before the tree is refused.
    public static let diffByteCap = 32 << 20

    /// The most untracked files hashed before the tree is refused.
    public static let untrackedFileCap = 2000

    /// The most untracked bytes hashed before the tree is refused.
    public static let untrackedByteCap: Int64 = 64 << 20

    /// How long every git call together may take before the tree is refused, because the run it keys waits on it to start.
    public static let budget: TimeInterval = 5

    /// The hex digest for the working tree at `repositoryRoot`, or `nil` when it is past a bound or git will not answer within `budget`.
    public static func of(repositoryRoot: URL, within budget: TimeInterval = TreeContentHash.budget) -> String? {
        let deadline = DispatchTime.now() + budget
        guard let head = output(["rev-parse", "--verify", "HEAD"], in: repositoryRoot, until: deadline)
            .flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !head.isEmpty,
            let listed = output(["ls-files", "-v", "-z"], in: repositoryRoot, until: deadline),
            hidesNothing(listed),
            let diff = diffDigest(in: repositoryRoot, until: deadline),
            let untracked = untrackedDigest(in: repositoryRoot, until: deadline)
        else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: Data(SHA256.hash(data: Data(head.utf8))))
        hasher.update(data: diff)
        hasher.update(data: untracked)
        return hex(hasher.finalize())
    }

    /// The tree a run of `arguments` starts on and the command line it was given there, or `nil` when the tree has no hash.
    public static func runKey(of arguments: [String], in workingDirectory: URL, repositoryRoot: URL) -> RunKey? {
        of(repositoryRoot: repositoryRoot).map { RunKey(tree: $0, invocation: invocation(of: arguments, in: workingDirectory, repositoryRoot: repositoryRoot)) }
    }

    /// The hex digest of the command line a run was given and the directory it was given in, relative to `repositoryRoot`.
    ///
    /// **The second half of what `flakes` compares a test's outcomes within.** The log keeps the tests that failed and not the tests that ran, so a `--filter` run that never reached a test cannot be told from one that passed it; only runs given the same command in the same place are known to have run the same tests. The directory is relative so two worktrees of one repository still share a key, and part of it because one argv in two packages runs two suites.
    public static func invocation(of arguments: [String], in workingDirectory: URL, repositoryRoot: URL) -> String {
        let root = repositoryRoot.resolvingSymlinksInPath().path
        let directory = workingDirectory.resolvingSymlinksInPath().path
        let relative = directory == root ? "." : directory.hasPrefix(root + "/") ? String(directory.dropFirst(root.count + 1)) : directory
        return hex(SHA256.hash(data: Data(([relative] + arguments).joined(separator: "\0").utf8)))
    }
}

public extension TreeContentHash {
    /// What a run is filed under for `flakes`: the content it started on, and the command line it was given.
    struct RunKey: Sendable, Equatable {
        /// The content hash of the tree the run started on.
        public let tree: String
        /// The digest of the command the run was given and where.
        public let invocation: String

        public init(tree: String, invocation: String) {
            self.tree = tree
            self.invocation = invocation
        }
    }
}

extension TreeContentHash {
    /// No repository (``ProcessEnvironment/withoutGit(from:)``) and `GIT_OPTIONAL_LOCKS=0`, so a read never takes `index.lock` to write a stat-cache refresh back.
    static func readEnvironment() -> [String: String] {
        var environment = ProcessEnvironment.withoutGit()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }
}

private extension TreeContentHash {
    /// Whether no index entry carries `assume-unchanged` (a lowercase tag) or `skip-worktree` (`S`), either of which keeps an edit out of the diff.
    static func hidesNothing(_ listed: Data) -> Bool {
        !listed.split(separator: 0).contains { entry in
            guard let tag = entry.first else { return false }
            return (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(tag) || tag == UInt8(ascii: "S")
        }
    }

    /// The digest of `git diff-index -p --binary HEAD`, streamed so a large diff is never held whole, or `nil` past ``diffByteCap`` or where a submodule is dirty.
    ///
    /// Submodules are reported by their commit whatever the configuration says to ignore, so a moved submodule is hashed by the commit it moved to; one with uncommitted content prints `-dirty` after that commit, and since no diff here carries that content the tree is refused. The last bytes of each chunk are carried into the next so the marker is found across a boundary.
    static func diffDigest(in directory: URL, until deadline: DispatchTime) -> Data? {
        let arguments = ["diff-index", "-p", "--binary", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=none", "--submodule=short", "HEAD"]
        let state = DiffState()
        let completed = stream(arguments, in: directory, until: deadline) { chunk in
            state.total += chunk.count
            let window = state.carry + chunk
            guard state.total <= diffByteCap, !namesADirtySubmodule(window) else {
                return false
            }
            state.hasher.update(data: chunk)
            state.carry = Data(window.suffix(128))
            return true
        }
        return completed ? Data(state.hasher.finalize()) : nil
    }

    /// Whether `window` holds a `+Subproject commit <id>-dirty` line.
    static func namesADirtySubmodule(_ window: Data) -> Bool {
        let marker = Data("-dirty\n".utf8)
        let line = Data("+Subproject commit ".utf8)
        var from = window.startIndex
        while let hit = window.range(of: marker, in: from ..< window.endIndex) {
            let start = window[from ..< hit.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? from
            if window[start ..< hit.lowerBound].starts(with: line) {
                return true
            }
            from = hit.upperBound
        }
        return false
    }

    /// The digest of every untracked, unignored path and its object id, in git's order, or `nil` past a bound.
    ///
    /// The tool's own directory is left out by pathspec rather than by writing an ignore rule: a run's transcript lands there, and hashing it would give every run a tree of its own. The listing is read only as far as ``untrackedFileCap``, so a tree with a hundred thousand untracked files is refused at the cap rather than listed first.
    static func untrackedDigest(in directory: URL, until deadline: DispatchTime) -> Data? {
        let listing = Accumulated()
        let listed = stream(["ls-files", "--others", "--exclude-standard", "-z", "--", ".", ":(exclude)\(SiftPaths.directoryName)"], in: directory, until: deadline) { chunk in
            listing.records += chunk.count { $0 == 0 }
            guard listing.records <= untrackedFileCap else {
                return false
            }
            listing.data.append(chunk)
            return true
        }
        guard listed else {
            return nil
        }
        let decoded = listing.data.split(separator: 0).map { String(data: Data($0), encoding: .utf8) }
        // A nested repository is listed as a directory: its bytes are in no diff here, so the tree is refused
        // rather than hashed by the name alone. A path that is not UTF-8 cannot be handed back to git by name,
        // and one holding a newline cannot go through `--stdin-paths` at all; both are refused the same way.
        guard !decoded.contains(nil) else {
            return nil
        }
        let paths = decoded.compactMap(\.self)
        guard !paths.contains(where: { $0.hasSuffix("/") || $0.contains("\n") }) else {
            return nil
        }
        var bytes: Int64 = 0
        for path in paths {
            bytes += (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)[.size] as? Int64) ?? 0
            if bytes > untrackedByteCap {
                return nil
            }
        }
        var ids: [String] = []
        if !paths.isEmpty {
            // `--no-filters`, so a clean filter — LFS, or anything a repository configures — is never run: it
            // may write, and the id wanted is of the bytes on disk.
            let input = Data((paths.joined(separator: "\n") + "\n").utf8)
            guard let hashed = output(["hash-object", "--no-filters", "--stdin-paths"], in: directory, input: input, until: deadline)
                .flatMap({ String(data: $0, encoding: .utf8) })
            else {
                return nil
            }
            ids = hashed.split(separator: "\n").map(String.init)
            guard ids.count == paths.count else {
                return nil
            }
        }
        var hasher = SHA256()
        for (path, id) in zip(paths, ids) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(id.utf8))
            hasher.update(data: Data([0x0A]))
        }
        return Data(hasher.finalize())
    }

    /// One git's whole stdout, or `nil` when it failed or did not finish by `deadline`.
    static func output(_ arguments: [String], in directory: URL, input: Data? = nil, until deadline: DispatchTime) -> Data? {
        let collected = Accumulated()
        let completed = stream(arguments, in: directory, input: input, until: deadline) { chunk in
            collected.data.append(chunk)
            return true
        }
        return completed ? collected.data : nil
    }

    /// Runs one git and hands its stdout to `consume` a chunk at a time; `true` only when git exited zero, `consume` never declined a chunk, and all of it happened by `deadline`.
    ///
    /// **The deadline is enforced from a second thread, and the child is killed rather than abandoned**, as ``RunChangedFiles`` does: a stalled git never reaches end of file, so the wait happens where the reading does not. A chunk `consume` declines kills the child too, which is how a bound stops a listing rather than reading it to the end. Past the deadline nothing more is read by the caller, so the reader's later writes land in state nobody looks at.
    static func stream(_ arguments: [String], in directory: URL, input: Data? = nil, until deadline: DispatchTime, consume: @escaping @Sendable (Data) -> Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ProcessEnvironment.gitHardening + arguments
        process.currentDirectoryURL = directory
        process.environment = readEnvironment()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil {
            // A child that exits before reading all of its input is then a write error, not a SIGPIPE that
            // takes this process down.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = stdin
        }
        // Awaited on the termination handler rather than `waitUntilExit`, which sleeps in a run loop for about
        // 65 ms whenever the child has not been reaped by the time it is called: `GitContext`'s reason.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else {
            ProcessStreams.abandon(stdout, stdin)
            return false
        }
        if let input {
            // Written from a thread of its own, because a long list fills the pipe before git has read it and
            // git fills its output pipe before this has drained it; one thread doing both deadlocks.
            let writer = Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            writer.name = "sift.tree-hash.stdin"
            writer.start()
        }
        let outcome = Completed()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            let handle = stdout.fileHandleForReading
            var accepted = true
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                if !consume(chunk) {
                    accepted = false
                    ChildDeadline.stop(process)
                    break
                }
            }
            try? handle.close()
            exited.wait()
            outcome.value = accepted && process.terminationReason == .exit && process.terminationStatus == 0
            finished.signal()
        }
        reader.name = "sift.tree-hash.stdout"
        reader.start()
        guard finished.wait(timeout: deadline) == .success else {
            ChildDeadline.stop(process)
            return false
        }
        return outcome.value
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A stream's bytes, and how many NUL-terminated records they hold, built up on the reading thread.
    ///
    /// Unchecked because the semaphore is the ordering: the reader writes before it signals, and the caller reads only after a successful wait.
    final class Accumulated: @unchecked Sendable {
        var data = Data()
        var records = 0
    }

    /// The diff's running hash, byte count and the tail carried into the next chunk, built up on the reading thread under ``Accumulated``'s ordering.
    final class DiffState: @unchecked Sendable {
        var hasher = SHA256()
        var total = 0
        var carry = Data()
    }

    /// Whether the reading thread saw git through to a clean exit, under ``Accumulated``'s ordering.
    final class Completed: @unchecked Sendable {
        var value = false
    }
}
