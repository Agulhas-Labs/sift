//
// Copyright © Agulhas Labs
//

import Foundation

/// The names of the files this working tree has changed, or the reason there is no such list.
///
/// This is the measurement that turns a wall of failures into an answer: failures landing only in files the tree has never touched are not this session's regression, whatever else they are. It is deliberately the **working tree against `HEAD`** and not a merge base, because the question asked at a gate is "is this mine, right now" rather than "what has this branch accumulated". **A file git does not yet track is in it**, unless git's ignore rules exclude it: a file created but never staged is as much this session's as one edited in place, and the commonest red run of all is a new test file failing before anyone has added it. Left out, every failure in that file would land outside the count and the line would read `0 in changed files` over a run whose failures are all the session's own — the most misleading answer in the most common case.
///
/// What it supports is a match **by filename, not by path**, because a filename is all the other side has: a Swift Testing issue line names `ZonePickTests.swift:13:9` and never a directory. Two files of the same name in different directories are indistinguishable here, which is why every rendering of the number says so — an approximate match presented as an exact one is the defect class this whole measurement exists to catch.
///
/// `.unavailable` is never to be read as "nothing changed". Outside a repository, or with git missing, the honest answer is that the signal is absent; a zero would be a claim, and the wrong one.
public enum RunChangedFiles: Sendable, Equatable {
    /// The basename of every path git reported — empty when the tree matches `HEAD` and holds no new file.
    case basenames(Set<String>)
    /// Why no list could be read, in git's own words.
    case unavailable(String)
}

public extension RunChangedFiles {
    /// How long the answer waits for git before going out without this signal.
    ///
    /// **The answer is what the caller is waiting on, and by the time this runs the wrapped command has already exited** — so a git that never returns holds back an exit code the caller's verify loop is blocked on, to supply one field of one line. That is the whole case for a deadline: `git diff` is fast until it is not (an fsmonitor hook that hangs, a cold network filesystem, contention on `index.lock`), and none of those is this tool's to diagnose.
    ///
    /// Two seconds, matching ``RunFailureSites/budget``, which bounds the other optional signal on this same path for the same reason.
    static let budget: TimeInterval = 2

    /// What `git status --untracked-files=all` reports for the repository enclosing `directory`, within `budget`: every path whose content differs from `HEAD`, staged or not, and every file git does not track and does not ignore.
    ///
    /// Git resolves the repository from the directory it runs in, and `status` answers for the whole working tree wherever that is, so any directory inside the checkout answers the same; one outside every checkout answers `.unavailable` with git's own refusal. Paths come back NUL-terminated (`-z`) because git's default quoting of non-ASCII paths would otherwise corrupt exactly the names this compares on.
    ///
    /// **`status` and not `git diff --name-only HEAD`, because this read must not write the index.** Both see a file whose stat changed and whose content did not — touched by a build, a checkout, an editor saving it unchanged — and settle it by content. The diff then writes the refreshed index back, taking `index.lock` to do it whatever `GIT_OPTIONAL_LOCKS` says, and another session committing in the same checkout at that instant fails on the lock. `status` refreshes in memory and, with optional locks off, writes nothing; the plumbing that writes nothing, `git diff-index`, settles nothing either, and would list the touched file as changed. One call also replaces the `ls-files --others` that used to follow the diff, with the same untracked paths.
    ///
    /// **Two of `status`'s own codes still need a second look, because `status` reports them against the index rather than against `HEAD`.** `AD` — added to the index, then deleted from disk — names a path `HEAD` never had and the working tree no longer has either: nothing to report, so it is dropped outright. `MM` — staged, then edited again in the working tree — can have landed back on `HEAD`'s own content, which is as unreported a change as any other revert; `MM` paths are checked against `HEAD`'s content directly (``revertedAgainstHead(_:in:)``), and one that matches is dropped too. Nothing else `status` reports needs this: every other code already compares by content against the tree it is asked about.
    static func inWorkingTree(at directory: URL, within budget: TimeInterval = RunChangedFiles.budget) -> RunChangedFiles {
        let deadline = DispatchTime.now() + budget
        guard let raw = run(["status", "--porcelain", "-z", "--untracked-files=all"], in: directory, until: deadline) else {
            return .unavailable("git did not answer in time")
        }
        guard raw.status == 0 else {
            return .unavailable(refusal(from: raw.streams.failure, status: raw.status))
        }
        let entries = statusEntries(inStatus: raw.streams.output).filter { $0.code != "AD" }
        let mmPaths = Set(entries.filter { $0.code == "MM" }.map(\.path))
        guard !mmPaths.isEmpty else {
            return of(entries.map(\.path))
        }
        let reverted = revertedAgainstHead(mmPaths, in: directory, until: deadline)
        return of(entries.map(\.path).filter { !reverted.contains($0) })
    }

    /// The same value built from paths already in hand, reduced to basenames the same way.
    static func of(_ paths: some Sequence<String>) -> RunChangedFiles {
        var basenames: Set<String> = []
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty {
                basenames.insert(name)
            }
        }
        return .basenames(basenames)
    }
}

extension RunChangedFiles {
    /// No repository (``ProcessEnvironment/withoutGit(from:)``) and `GIT_OPTIONAL_LOCKS=0`, so a read never takes `index.lock` to write a stat-cache refresh back.
    static func readEnvironment() -> [String: String] {
        var environment = ProcessEnvironment.withoutGit()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// The most bytes ``revertedAgainstHead(_:in:until:)`` will read, across every `MM` path, to compare them against `HEAD`.
    ///
    /// Large enough for any ordinary set of source files to clear it; past it, reading both sides whole to settle a path risks the run's own deadline for a signal the answer can do without — the path just stays listed, the direction that was already safe for everything else this type reports.
    static let revertCompareSizeCap = 5_000_000

    /// Which of `paths` — every one reported `MM` — actually still differ from `HEAD`'s own content: the rest are staged changes the working tree has since put back, unreported the way any other revert is.
    ///
    /// **Reads the two sides straight, rather than asking `git diff` to compare them.** A `--name-only` diff against the working tree cannot look at content when it must not refresh the index (``GitContext``'s reason for `diff.autoRefreshIndex=false`): denied a refresh, it falls back to a stat comparison and reports every one of these paths as still different, which is precisely the false positive this function exists to rule out — `status` already avoided it by comparing content itself. `git cat-file --batch`, behind ``GitContext/blobs(_:)``, touches neither the index nor its stat cache at all, so the two sides can be compared as bytes with nothing to refresh. `HEAD` failing to resolve, or a path missing from either side, leaves that path "still changed" — the same bias toward reporting a change as against missing one that `.unavailable` elsewhere in this type protects.
    ///
    /// **Bounded by `deadline`, the same one the caller is already waiting on.** Every path is first settled by size alone — a stat of the working copy, `git cat-file -s` for `HEAD`'s — and only paths whose sizes match, and which together sit under ``revertCompareSizeCap``, ever have their bytes read; a size call past `deadline`, or the loop finding no time left before it starts, leaves the remaining paths "still changed" rather than block the caller on a blob neither side needed to read.
    static func revertedAgainstHead(_ paths: Set<String>, in directory: URL, until deadline: DispatchTime = .distantFuture) -> Set<String> {
        guard let root = GitContext.discoverRoot(from: directory) else { return [] }
        var eligible: [String] = []
        var eligibleBytes = 0
        for path in paths.sorted() {
            guard DispatchTime.now() < deadline else { break }
            guard let onDiskSize = fileSize(at: root.appendingPathComponent(path)), eligibleBytes + onDiskSize <= revertCompareSizeCap,
                  let headSize = headBlobSize(path, in: root, until: deadline), headSize == onDiskSize
            else { continue }
            eligible.append(path)
            eligibleBytes += onDiskSize
        }
        guard !eligible.isEmpty, DispatchTime.now() < deadline,
              let blobs = try? GitContext(repoRoot: root).blobs(eligible.map { (rev: "HEAD", path: $0) })
        else { return [] }
        var reverted: Set<String> = []
        for (path, blob) in zip(eligible, blobs) {
            guard let blob, let onDisk = try? Data(contentsOf: root.appendingPathComponent(path)), blob == onDisk else { continue }
            reverted.insert(path)
        }
        return reverted
    }
}

private extension RunChangedFiles {
    /// One `git status`'s two streams and exit status, or `nil` past `deadline` — the raw material `inWorkingTree` reads.
    ///
    /// **Its own `git` runner rather than ``GitContext``'s**, which is private and throws a `GitError` carrying one composed sentence. The wording here has to be git's own first sentence and its exit status — the two things that composition has already spent — so reaching for it would mean either parsing a message back apart or widening `GitContext`'s surface for a single caller. Both are worse than a dozen lines of `Process`.
    ///
    /// **The deadline is enforced from a second thread, and the child is killed rather than abandoned.** `ProcessStreams.drain` returns when both pipes reach end of file, which a stalled git never reaches, so the wait has to happen somewhere the answer is not. On expiry `nil` comes back — the caller's to report unavailable, since the state this type models must never be read as zero.
    static func run(_ arguments: [String], in directory: URL, until deadline: DispatchTime) -> (streams: (output: Data, failure: Data), status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ProcessEnvironment.gitHardening + arguments
        process.currentDirectoryURL = directory
        // No repository in the environment, for ``GitContext``'s reason: a wrapped run started from a git
        // hook inherits its `GIT_DIR`, and this diff would then describe the hook's repository — reported
        // as "in changed files" against a command run somewhere else entirely.
        // Optional locks off, so `status` writes back none of the index refresh it makes — see `inWorkingTree`.
        process.environment = readEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            ProcessStreams.abandon(stdout, stderr)
            return (streams: (output: Data(), failure: Data("git could not be run: \(error.localizedDescription)".utf8)), status: 1)
        }
        let answered = Answer()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
            process.waitUntilExit()
            answered.value = (streams, process.terminationStatus)
            finished.signal()
        }
        reader.name = "sift.run.changed-files"
        reader.start()
        guard finished.wait(timeout: deadline) == .success, let answer = answered.value else {
            ChildDeadline.stop(process)
            return nil
        }
        return answer
    }

    /// What the thread reading git hands back, when it gets there before the deadline does.
    ///
    /// Unchecked because the semaphore is the ordering: the write happens before the signal and the read only ever after a successful wait. Past the deadline nothing is read at all, which is what makes the abandoned thread's later write harmless.
    final class Answer: @unchecked Sendable {
        var value: (streams: (output: Data, failure: Data), status: Int32)?
    }

    /// The path and status code each `status --porcelain -z` record names — `XY path` — where a rename or copy (`R`, `C` in either column) is followed by a record of its own holding the path it came from.
    ///
    /// That source record is skipped, so a rename counts its new name only.
    ///
    /// **Each NUL-separated record is decoded on its own**, and that is the whole reason `-z` is worth reading this way. Decoding the buffer whole through `String(data:encoding:)` makes one path that is not valid UTF-8 — a Linux checkout, a submodule, an archive unpacked in another encoding — answer `nil` for the *entire* payload, which falls through to an empty list and prints `0 in changed files (matched by name)` over a tree where forty files have changed. That is the one reading this type's own doc says must never happen: a zero would be a claim, and the wrong one. Per-record, the forty are still forty and the one that cannot be spelled is simply a name nothing will match — which is the truth about it, since the framework on the other side of the comparison prints UTF-8 by construction.
    static func statusEntries(inStatus output: Data) -> [(code: String, path: String)] {
        var entries: [(code: String, path: String)] = []
        var records = output.split(separator: 0).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { continue }
            // The status code is always ASCII (a letter, `?` or a space), so decoding it lossily loses
            // nothing; the path is lossy on purpose, per this function's own doc: the failable initializer
            // is exactly the whole-payload `nil` described there, one record at a time. `no_swiftlint_disable`
            // rides along because the directive is what it objects to.
            let code = String(decoding: record.prefix(2), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
            let path = String(decoding: record.dropFirst(3), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
            entries.append((code, path))
            if code.contains("R") || code.contains("C") {
                _ = records.next()
            }
        }
        return entries
    }

    /// The working copy's byte count for `path`, `nil` when it cannot be stat'd — the cheap first read ``revertedAgainstHead(_:in:until:)`` settles most paths with.
    static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// `HEAD`'s byte count for `path` — `git cat-file -s`, never the blob's own bytes, so a size check never has to read what it might rule out.
    static func headBlobSize(_ path: String, in root: URL, until deadline: DispatchTime) -> Int? {
        guard let raw = run(["cat-file", "-s", "HEAD:\(path)"], in: root, until: deadline), raw.status == 0 else { return nil }
        // `-s`'s whole answer is one ASCII decimal line, so a lossy decode loses nothing worth keeping.
        let text = String(decoding: raw.streams.output, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Git's refusal in git's own words: its first sentence, without the severity it prefixes the line with or the full stop it ends on.
    ///
    /// Kept verbatim otherwise, because a reason this type worded itself would be a second thing to be wrong about. The trimming is only of what says nothing here — the `fatal:` or `warning:` git opens the line with, and any advice it appends for someone typing the command by hand, which is not this reader's problem.
    ///
    /// Decoded lossily for the reason ``statusEntries(_:)`` decodes per record: a refusal that quotes an undecodable path would otherwise become `git exited 129 without saying why`, which is the same silence one byte away.
    static func refusal(from data: Data, status: Int32) -> String {
        // Lossy on purpose, per the paragraph above: a failable decode turns a refusal that quotes an
        // undecodable path into `git exited 129 without saying why`, which is the silence to avoid.
        let text = String(decoding: data, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
        guard let line = text.split(separator: "\n").first else {
            return "git exited \(status) without saying why"
        }
        var sentence = line.trimmingCharacters(in: .whitespaces)
        if let severity = ["fatal: ", "error: ", "warning: "].first(where: { sentence.hasPrefix($0) }) {
            sentence = String(sentence.dropFirst(severity.count))
        }
        if let stop = sentence.range(of: ". ") {
            sentence = String(sentence[..<stop.lowerBound])
        }
        return sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }
}
