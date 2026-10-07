//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation

/// Takes the uncommitted changes under a pathspec out of a working tree, and puts them back byte for byte.
///
/// **Setting aside makes every recorded path read exactly as HEAD has it — in the index and in the working tree — and nothing else.** The index matters as well as the files because a build is not the only reader: a test that lists what git tracks, or checks that the tree is clean, runs against the index, and a tree whose files are HEAD's while its index still stages the change is a state no commit ever had. Only paths git reports as changed are touched, and every write to the index goes through git's own plumbing, so nothing outside the pathspec moves.
///
/// **Never check, then write.** Every step that could replace or remove something at a user's path goes through an operation that cannot do so silently — an exclusive rename that fails if anything is there, or a swap after which what came out is looked at — and whatever comes out that is not this tool's is kept, beside the path, and said. Nothing in the tree is ever unlinked: what has to go is moved into the store first and looked at there. Nothing is moved on the strength of what was true when it was recorded either: each file is moved out of the tree in one exclusive rename and checked against its copy the moment it lands in the store, and HEAD's version goes in only by an exclusive rename. A path that changed stops the whole set-aside: whatever was already set aside goes back, the changed path is left as its writer left it, and nothing runs.
///
/// **HEAD's version is written by this process, never by a git child.** It is prepared in the store first — one `git checkout-index` into the store, which applies the repository's smudge filters and line-ending rules exactly as a checkout would — and only then renamed into place. A git that wrote the tree itself could outlive a run killed part-way, and go on writing after the watcher had put everything back.
///
/// **Restoring puts back the bytes and the index entries, not an equivalent of them, and checks them by content.** Each file comes back from a copy taken before the tree was touched, with its permission bits; each index entry from its recorded mode and object, re-inserting the object from a copy if the object database lost it in the meantime. It is checked afterwards against the record — every file's SHA-256, and every path's index entry — and the record is removed only once both agree. Neither side of the check depends on HEAD, so a branch switched or a commit made while the tests ran is reported, not mistaken for lost work. Timestamps are deliberately not restored: a build system that saw a file's old timestamp could keep the objects it compiled from the set-aside version.
///
/// **A restore never destroys bytes it did not write.** Anything it takes out of the tree to put a path back is moved into the store and looked at before the record goes; whatever is neither what was recorded nor anything this tool left there was written by somebody else while the tests ran, and it is moved beside the path under a `.sift-kept-` name.
public struct SetAside: Sendable {
    public let store: SetAsideStore
    /// Every git this runs is one of these, so a watcher can end it before restoring.
    public let children: SetAsideChildren

    public init(store: SetAsideStore, children: SetAsideChildren = SetAsideChildren()) {
        self.store = store
        self.children = children
    }
}

// MARK: - Capture

public extension SetAside {
    /// Reads what is uncommitted under `pathspecs` from `directory` — or, where `since` names a commit, what the commits since it changed under them — copies every byte of it into the store, and writes the record, touching nothing in the tree.
    ///
    /// `since` is a commit git has already resolved, and the paths are then set aside to it rather than to HEAD: the change it sets aside is the one already committed on top of it. The two sources never mix, so a working tree with anything uncommitted under `pathspecs` is refused rather than folded in.
    ///
    /// After this returns the record is on disk, flushed, and complete; before it returns there is no record, and a capture that fails or is `cancelled` part-way takes the copies it had made with it. `cancelled` is asked before each path and before the record is written — how an interruption during a long capture ends it without leaving anything behind.
    static func capture(
        pathspecs: [String],
        from directory: URL,
        into store: SetAsideStore,
        children: SetAsideChildren = SetAsideChildren(),
        id: String = UUID().uuidString,
        owner: Int32 = getpid(),
        since: String? = nil,
        cancelled: () -> Bool = { false }
    ) throws -> SetAsideRecord {
        let root = store.repositoryRoot
        let git = SetAsideGit(directory: root, children: children)
        guard let head = try? git.text(["rev-parse", "--verify", "--quiet", "HEAD"]), !head.isEmpty else {
            throw SetAsideError.noCommit
        }
        let local = SetAsideGit(directory: directory, repositoryRoot: root, children: children)
        let prefix = try local.text(["rev-parse", "--show-prefix"])
        let (lines, own) = try SetAsideStatusLine.parse(local.run(SetAsideStatusLine.arguments(pathspecs)), flag: "--without")
        let changes: [Change]
        var leftInPlace = own
        if let since {
            // The two sources are never mixed in one run: a change in the tree would go out with the
            // committed one and come back as part of it.
            guard lines.isEmpty else {
                throw SetAsideError.uncommittedUnder(paths: lines.map(\.path), pathspecs: pathspecs, since: since)
            }
            let committed = try Change.committed(since: since, pathspecs: pathspecs, git: local)
            changes = committed.changes
            leftInPlace += committed.own
            guard !changes.isEmpty else {
                let listed = try local.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] + pathspecs)
                throw SetAsideError.nothingSince(pathspecs: pathspecs, since: since, matchesFiles: !listed.isEmpty, leftInPlace: leftInPlace)
            }
        } else {
            guard !lines.isEmpty else {
                let listed = try local.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] + pathspecs)
                let committedSince = listed.isEmpty ? nil : Self.committedBase(pathspecs: pathspecs, root: root, git: local)
                throw SetAsideError.nothingUncommitted(pathspecs: pathspecs, matchesFiles: !listed.isEmpty, leftInPlace: own, committedSince: committedSince)
            }
            changes = lines.map(Change.init)
        }
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
        try refuseWhatCannotBeReproduced(changes, prefix: prefix, revision: since ?? "HEAD", uncommitted: since == nil, git: git, caseSensitive: caseSensitive)

        // Checked here as well as by every caller: clearing the store below would take an unrestored
        // record's copies with it, and a caller that forgot to look is not a reason to lose them.
        if let existing = try store.record() {
            throw SetAsideError.unrestored(existing)
        }
        try? FileManager.default.removeItem(at: store.directory)
        do {
            try FileManager.default.createDirectory(at: store.copies, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: store.blobs, withIntermediateDirectories: true)
            let tree = SetAsideTree(root: root)
            let storeDevice = SetAsideTree.device(atPath: store.directory.path)
            var listings: [String: [String]] = [:]
            var entries: [SetAsideRecord.Entry] = []
            var staged: [String] = []
            for (number, change) in changes.enumerated() {
                if cancelled() {
                    throw SetAsideError.cancelled
                }
                let disk = tree.onDisk(change.path, caseSensitive: caseSensitive, cache: &listings)
                // Every move the set-aside makes is one rename into the store and one back, which a path on
                // another volume could not take.
                if let storeDevice, let device = tree.device(of: disk), device != storeDevice {
                    throw SetAsideError.unsupported(path: change.path, reason: "it is on another volume than \(SiftPaths.directoryName)/, so it could not be moved aside in one step", flag: "--without")
                }
                let index = change.index
                if case let .entry(entry) = index, entry != change.head {
                    staged.append(entry.object)
                }
                try entries.append(SetAsideRecord.Entry(
                    path: change.path,
                    disk: Array(disk.utf8) == Array(change.path.utf8) ? nil : disk,
                    status: change.status,
                    head: change.head,
                    index: index,
                    worktree: worktreeState(of: disk, shown: change.path, in: tree, copyingInto: store.copies, as: "\(number)", flag: "--without")
                ))
            }
            // Copied rather than trusted to stay: once the index stops naming a staged object it is
            // unreferenced, and a `git gc` during the run is free to prune it.
            try git.copyObjects(staged, into: store.blobs)
            if cancelled() {
                throw SetAsideError.cancelled
            }
            let record = SetAsideRecord(id: id, pathspecs: pathspecs, directory: prefix, head: head, since: since, owner: owner, entries: entries, leftInPlace: leftInPlace)
            try store.writeDurably(record, to: store.recordURL)
            return record
        } catch {
            // No record was written — its rename is the last step — so everything here is a copy nobody points at.
            try? FileManager.default.removeItem(at: store.directory)
            throw error
        }
    }

    /// The states a set-aside could not put back exactly, refused before anything is copied.
    ///
    /// `revision` is the commit the paths would be set aside to, and `uncommitted` whether the change being set aside is one in the tree — the two facts the refusals' wording turns on.
    private static func refuseWhatCannotBeReproduced(_ changes: [Change], prefix: String, revision: String, uncommitted: Bool, git: SetAsideGit, caseSensitive: Bool) throws {
        let named = uncommitted ? "HEAD" : revision
        for change in changes {
            if let reason = change.unsupported {
                throw SetAsideError.unsupported(path: change.path, reason: reason, flag: "--without")
            }
            if let head = change.head, !Change.reproducibleModes.contains(head.mode) {
                throw SetAsideError.unsupported(path: change.path, reason: "\(named) records it with mode \(head.mode)", flag: "--without")
            }
        }
        // Setting aside a directory that commit does not have would take the directory this command runs in with it.
        if !prefix.isEmpty, (try? git.run(["cat-file", "-e", "\(revision):\(prefix)"])) == nil {
            let why = uncommitted ? "the current directory is itself uncommitted" : "\(named) has no such directory"
            throw SetAsideError.unsupported(path: prefix, reason: "\(why), so setting it aside would remove the directory the command runs in", flag: "--without")
        }
        guard !caseSensitive else {
            return
        }
        var seen: [String: String] = [:]
        for change in changes {
            let folded = change.path.lowercased()
            if let other = seen[folded], other != change.path {
                throw SetAsideError.unsupported(path: change.path, reason: "it and \(other) differ only in case, which this volume cannot hold apart", flag: "--without")
            }
            seen[folded] = change.path
        }
    }

    /// What the working tree holds at `disk`, with a copy of it in the store when it is a file.
    ///
    /// `flag` names the run this reads for, so a refusal reads as the caller's own command.
    internal static func worktreeState(of disk: String, shown: String, in tree: SetAsideTree, copyingInto copies: URL, as name: String, flag: String) throws -> SetAsideRecord.WorktreeState {
        let path = tree.absolute(disk)
        switch try SetAsideFingerprint.kind(path) {
        case .absent:
            return .absent
        case let .file(permissions):
            let copy = copies.appendingPathComponent(name).path
            guard copyfile(path, copy, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL)) == 0 else {
                throw SetAsideError.store("could not copy \(shown) into \(SiftPaths.directoryName)/set-aside/: \(String(cString: strerror(errno)))")
            }
            return try .file(permissions: permissions, sha256: SetAsideFingerprint.sha256(copy), copy: name)
        case .symlink:
            return try .symlink(target: SetAsideFingerprint.target(of: path))
        case .directory:
            throw SetAsideError.unsupported(path: shown, reason: "a directory stands where git records a file", flag: flag)
        case .other:
            throw SetAsideError.unsupported(path: shown, reason: "it is neither a regular file nor a symbolic link", flag: flag)
        }
    }
}

// MARK: - Setting aside

public extension SetAside {
    /// How a set-aside ended.
    enum Outcome: Sendable {
        /// Every recorded path reads as HEAD has it.
        case setAside
        /// A path changed after it was recorded, so the set-aside stopped: the paths that changed, left as their writer left them, and what was put back of the rest — nothing was run.
        case stopped(changed: [String], restored: Restored)
    }

    /// Makes every recorded path read exactly as the commit it was recorded against has it — HEAD, or the revision a `--since` run named — in the index and the working tree, or stops, puts back what it had set aside, and says which path changed under it.
    ///
    /// Safe to be interrupted at any point, because the record already holds everything a restore needs, and a restore starts from whatever state it finds. Throws ``SetAsideError/notRestored(_:)`` — never stopping quietly — when somebody's bytes it found could not be kept anywhere but the store: the record then stays, and so does every copy.
    func setAside(_ record: SetAsideRecord) throws -> Outcome {
        let tree = SetAsideTree(root: store.repositoryRoot)
        let git = SetAsideGit(directory: store.repositoryRoot, children: children)
        try FileManager.default.createDirectory(at: store.moved, withIntermediateDirectories: true)

        // HEAD's version of every path, prepared before anything moves — and what the set-aside will leave
        // at each path written down before anything moves too, so a restore always knows its own work.
        let prepared = try record.line.map { try prepareLine(record, $0, at: headVersion) } ?? prepare(record, git: git)
        try store.writeDurably(prepared.mapValues { [$0] }, to: store.asideURL)

        // The index, checked against the record before a single entry is written: nothing has moved yet,
        // so a path somebody staged since it was recorded ends the set-aside with nothing to put back.
        let current = try indexNow(record, git: git)
        let restaged = record.entries.filter { !Self.matches($0.index, current[$0.path]) }.map(\.path)
        guard restaged.isEmpty else {
            try store.discard()
            return .stopped(changed: restaged, restored: Restored(record: record, kept: [], headNow: nil))
        }
        let zero = String(repeating: "0", count: record.head.count)
        let indexInfo = record.entries.filter(\.indexDiffersFromHead).map { entry in
            entry.head.map { "\($0.mode) \($0.object)\t\(entry.path)" } ?? "0 \(zero)\t\(entry.path)"
        }
        if !indexInfo.isEmpty {
            try git.run(["update-index", "-z", "--index-info"], input: SetAsideTree.terminated(indexInfo))
        }

        var kept: [String] = []
        var removed: [String] = []
        for (number, entry) in record.entries.enumerated() where !placesAVersion(at: entry, of: record) {
            guard try moveAway(entry, as: "\(number)", record: record, tree: tree, kept: &kept) else {
                return try stop(record, changed: entry.path, kept: kept)
            }
            removed.append(entry.onDisk)
        }
        tree.pruneEmptyDirectories(above: removed)
        for (number, entry) in record.entries.enumerated() {
            guard placesAVersion(at: entry, of: record), let target = prepared[entry.path] else {
                continue
            }
            let original = SetAsideFingerprint(entry.worktree)
            if original == target {
                // The tree already holds HEAD's version here; the index was the whole of the change.
                guard try SetAsideFingerprint.read(tree.absolute(entry.onDisk)) == original else {
                    return try stop(record, changed: entry.path, kept: kept)
                }
                continue
            }
            if original != .absent {
                guard try moveAway(entry, as: "\(number)", record: record, tree: tree, kept: &kept) else {
                    return try stop(record, changed: entry.path, kept: kept)
                }
            }
            guard try place(from: headVersion(of: entry), at: entry.onDisk, tree: tree) else {
                // Something appeared at the path after its original left it: that write stays where it is, and
                // the original — somebody's uncommitted work — goes beside it, or the set-aside stops with it
                // still in the store and says so.
                let moved = store.moved.appendingPathComponent("\(number)").path
                if try SetAsideFingerprint.read(moved) != .absent {
                    try kept.append(keep(moved, beside: entry, what: "the version that had been there", record: record, tree: tree))
                }
                return try stop(record, changed: entry.path, kept: kept)
            }
        }
        return .setAside
    }

    /// Whether the set-aside puts a version of its own at `entry`'s path — the commit's, or the file with its line commented out — rather than only taking away what stands there.
    private func placesAVersion(at entry: SetAsideRecord.Entry, of record: SetAsideRecord) -> Bool {
        record.line != nil || entry.head != nil
    }

    /// Where the prepared version of `entry` — the one the set-aside will put in its place — stands in the store.
    private func headVersion(of entry: SetAsideRecord.Entry) -> String {
        "\(store.heads.path)/\(entry.path)"
    }

    /// The recorded version of every path the commit being set aside to has, written into the store by one `git checkout-index` — through the repository's own smudge filters and line-ending rules, exactly as a checkout would write it — and what each will read as once it stands in the tree; `.absent` for the paths that commit does not have.
    ///
    /// From an index of its own holding only HEAD's entries: the repository's index is the caller's, and stages their changes. One process for every path, where one per path cost more than everything else a set-aside did.
    private func prepare(_ record: SetAsideRecord, git: SetAsideGit) throws -> [String: SetAsideFingerprint] {
        var prepared: [String: SetAsideFingerprint] = [:]
        var heads: [String] = []
        var paths: [String] = []
        for entry in record.entries {
            guard let head = entry.head else {
                prepared[entry.path] = .absent
                continue
            }
            heads.append("\(head.mode) \(head.object)\t\(entry.path)")
            paths.append(entry.path)
        }
        guard !paths.isEmpty else {
            return prepared
        }
        let environment = ["GIT_INDEX_FILE": store.headsIndex.path]
        // An index nobody else reads: none of the repository's own index extensions belong in it. (git reads
        // its configuration keys without regard to case.)
        let settings = ["-c", "core.splitindex=false", "-c", "core.untrackedcache=false", "-c", "core.fsmonitor=false"]
        try git.run(settings + ["update-index", "-z", "--index-info"], input: SetAsideTree.terminated(heads), environment: environment)
        try git.run(settings + ["checkout-index", "--prefix=\(store.heads.path)/", "-z", "--stdin"], input: SetAsideTree.terminated(paths), environment: environment)
        for entry in record.entries where entry.head != nil {
            prepared[entry.path] = try SetAsideFingerprint.read(headVersion(of: entry))
        }
        return prepared
    }

    /// Moves a recorded file out of the tree into the store in one exclusive rename, and checks it is what was recorded; `false` when it was not — somebody wrote it, or removed it, after it was recorded — with their version put back where it was, or kept beside it if the path has been taken again since.
    private func moveAway(_ entry: SetAsideRecord.Entry, as name: String, record: SetAsideRecord, tree: SetAsideTree, kept: inout [String]) throws -> Bool {
        let source = tree.absolute(entry.onDisk)
        let destination = store.moved.appendingPathComponent(name).path
        let code = SetAsideTree.moveExclusively(source, to: destination)
        guard code == 0 else {
            if code == ENOENT {
                return false
            }
            throw SetAsideError.store("could not move \(entry.path) into \(SiftPaths.directoryName)/set-aside/: \(String(cString: strerror(code)))")
        }
        guard try SetAsideFingerprint.read(destination) != SetAsideFingerprint(entry.worktree) else {
            return true
        }
        if SetAsideTree.moveExclusively(destination, to: source) != 0 {
            try kept.append(keep(destination, beside: entry, what: "the write found there", record: record, tree: tree))
        }
        return false
    }

    /// Puts HEAD's prepared version at `relative` without replacing anything; `false` when something is already there.
    private func place(from source: String, at relative: String, tree: SetAsideTree) throws -> Bool {
        let code = tree.makeParents(of: relative)
        guard code == 0 else {
            if code == ENOTDIR {
                return false
            }
            throw SetAsideError.store("could not create the directories above \(relative): \(String(cString: strerror(code)))")
        }
        let moved = SetAsideTree.moveExclusively(source, to: tree.absolute(relative))
        guard moved == 0 else {
            if moved == EEXIST {
                return false
            }
            throw SetAsideError.store("could not put HEAD's version of \(relative) in place: \(String(cString: strerror(moved)))")
        }
        return true
    }

    /// Moves somebody's bytes from the store to a name beside the path they belong to — or, when that cannot be done, stops the set-aside with the record kept, saying the work is not back and where the bytes are.
    private func keep(_ source: String, beside entry: SetAsideRecord.Entry, what: String, record: SetAsideRecord, tree: SetAsideTree) throws -> String {
        do {
            return try tree.keep(source, beside: entry.onDisk, id: record.id)
        } catch {
            let inStore = store.shownDirectory + source.dropFirst(store.directory.path.count + 1)
            throw SetAsideError.notRestored(SetAsideError.NotRestored(
                reasons: ["\(entry.path) changed while it was being set aside, and \(what) \(SetAsideError.reason(error)): it is at \(inStore)"],
                invocation: record.invocation,
                store: store.shownDirectory,
                id: record.id
            ))
        }
    }

    /// Ends a set-aside that found a path changed under it: everything else goes back, and the changed path is left as its writer left it.
    private func stop(_ record: SetAsideRecord, changed: String, kept: [String]) throws -> Outcome {
        let restored = try restore(record, sparing: [changed])
        return .stopped(
            changed: [changed],
            restored: Restored(record: record, kept: kept + restored.kept, headNow: restored.headNow, indexLeft: restored.indexLeft)
        )
    }
}

// MARK: - Restoring

public extension SetAside {
    /// What a restore put back.
    struct Restored: Sendable {
        public let record: SetAsideRecord
        /// Paths holding what somebody wrote into a recorded path while it was set aside, each kept beside the path it was found at.
        public let kept: [String]
        /// The commit HEAD names now, where it no longer names the one the paths were set aside to — the bytes came back, and HEAD moving under them is the caller's to know.
        public let headNow: String?
        /// Paths a stopped set-aside left as their writer left them whose index entry had been staged again as well — that staging left as it was made, rather than put back over.
        public let indexLeft: [String]
        /// How many processes the run had left running, ended before the tree was put back — what a `run --restore` finds from the store when the run and its watcher are both gone.
        public let ended: Int

        init(record: SetAsideRecord, kept: [String], headNow: String?, indexLeft: [String] = [], ended: Int = 0) {
            self.record = record
            self.kept = kept
            self.headNow = headNow
            self.indexLeft = indexLeft
            self.ended = ended
        }

        /// The same restore, counting `ended` processes ended before it.
        func ending(_ ended: Int) -> Restored {
            Restored(record: record, kept: kept, headNow: headNow, indexLeft: indexLeft, ended: ended)
        }
    }

    /// Puts every recorded path back as it was, checks it, and removes the record.
    ///
    /// Throws ``SetAsideError/notRestored(_:)`` — whatever stopped it, a failed check or a git error — and keeps the record and every copy. Starts from whatever the tree holds — untouched, half set aside, fully set aside, half restored — so running it twice, or after a run that was killed at any point, is always safe. `sparing` names paths whose working-tree file is left exactly as it stands: the ones a stopped set-aside found somebody else had written.
    func restore(_ record: SetAsideRecord, sparing: Set<String> = [], requested: Bool = false) throws -> Restored {
        do {
            return try putBack(record, sparing: sparing)
        } catch let error as SetAsideError {
            throw failure(error, of: record, requested: requested)
        } catch {
            throw failure(.store("\(error)"), of: record, requested: requested)
        }
    }

    /// Every way the tree differs from the record: each file's kind, bits and SHA-256, then each path's entry in the index.
    func differences(from record: SetAsideRecord, sparing: Set<String> = []) throws -> [String] {
        try differences(from: record, sparing: sparing, indexLeft: [])
    }
}

extension SetAside {
    /// How many times a restore goes round before it says the tree is not back: a write landing on a path after that path was put back is taken out and kept on the next round, rather than failing the check.
    static let restoreRounds = 3

    private func differences(from record: SetAsideRecord, sparing: Set<String>, indexLeft: Set<String>) throws -> [String] {
        let tree = SetAsideTree(root: store.repositoryRoot)
        var differences: [String] = []
        for entry in record.entries where !sparing.contains(entry.path) {
            let current = try SetAsideFingerprint.read(tree.absolute(entry.onDisk))
            let expected = SetAsideFingerprint(entry.worktree)
            if current != expected {
                differences.append("\(entry.path): expected \(expected.described), found \(current.described)")
            }
        }
        let current = try indexNow(record, git: SetAsideGit(directory: store.repositoryRoot, children: children))
        for entry in record.entries where !indexLeft.contains(entry.path) && !Self.matches(entry.index, current[entry.path]) {
            differences.append("\(entry.path): the index holds \(Self.described(current[entry.path])) where it held \(Self.described(entry.index))")
        }
        return differences
    }

    private func putBack(_ record: SetAsideRecord, sparing: Set<String>) throws -> Restored {
        let tree = SetAsideTree(root: store.repositoryRoot)
        let git = SetAsideGit(directory: store.repositoryRoot, children: children)
        guard var ours = try store.ours() else {
            // Written before the index or any file changes, so without it nothing was ever touched: the tree
            // is the caller's own, whatever it holds.
            let headNow = headMove(record, git: git)
            try store.discard()
            return Restored(record: record, kept: [], headNow: headNow)
        }
        var kept: [String] = []
        var indexLeft: [String] = []
        for round in 1 ... Self.restoreRounds {
            let intents: [String]
            (intents, indexLeft) = try restoreIndex(record, sparing: sparing, git: git)
            try removeWhatWasAbsent(record, sparing: sparing, tree: tree)
            for (number, entry) in record.entries.enumerated() where entry.worktree != .absent && !sparing.contains(entry.path) {
                try kept.append(contentsOf: restoreLeaf(entry, number: number, record: record, ours: &ours, tree: tree))
            }
            if !intents.isEmpty {
                try git.runWaitingForIndexLock(
                    ["--literal-pathspecs", "add", "--intent-to-add", "--pathspec-from-file=-", "--pathspec-file-nul"],
                    input: SetAsideTree.terminated(intents)
                )
            }
            try kept.append(contentsOf: sweep(record, sparing: sparing, ours: ours, tree: tree))
            let differences = try differences(from: record, sparing: sparing, indexLeft: Set(indexLeft))
            if differences.isEmpty {
                break
            }
            guard round < Self.restoreRounds else {
                throw SetAsideError.notRestored(SetAsideError.NotRestored(reasons: differences, invocation: record.invocation, store: store.shownDirectory, id: record.id))
            }
        }
        let headNow = headMove(record, git: git)
        try store.discard()
        return Restored(record: record, kept: kept, headNow: headNow, indexLeft: indexLeft)
    }

    /// Takes out of the tree whatever stands at a path that held nothing — HEAD's version the set-aside put there, or somebody's write — each by one exclusive move into the store, never an unlink: the sweep before the record goes looks at what came out, and keeps beside the path anything that is not this tool's.
    private func removeWhatWasAbsent(_ record: SetAsideRecord, sparing: Set<String>, tree: SetAsideTree) throws {
        var removed: [String] = []
        for (number, entry) in record.entries.enumerated() where entry.worktree == .absent && !sparing.contains(entry.path) {
            switch try SetAsideFingerprint.kind(tree.absolute(entry.onDisk)) {
            case .file, .symlink, .other:
                if try displace(tree.absolute(entry.onDisk), number: number, shown: entry.path) {
                    removed.append(entry.onDisk)
                }
            case .absent, .directory:
                break
            }
        }
        tree.pruneEmptyDirectories(above: removed)
    }

    /// Puts one recorded path back, unless it already holds exactly what was recorded, and answers anything it had to keep aside first.
    ///
    /// Built in full in the store, then put in place without destroying what stands there.
    private func restoreLeaf(
        _ entry: SetAsideRecord.Entry,
        number: Int,
        record: SetAsideRecord,
        ours: inout [String: [SetAsideFingerprint]],
        tree: SetAsideTree
    ) throws -> [String] {
        let recorded = SetAsideFingerprint(entry.worktree)
        guard try SetAsideFingerprint.read(tree.absolute(entry.onDisk)) != recorded else {
            return []
        }
        var kept: [String] = []
        if let blocking = tree.obstruction(above: entry.onDisk) {
            try kept.append(keep(tree.absolute(blocking), beside: blocking, shown: blocking, record: record, tree: tree))
        }
        let code = tree.makeParents(of: entry.onDisk)
        guard code == 0 else {
            throw SetAsideError.store("could not create the directories above \(entry.path): \(String(cString: strerror(code)))")
        }
        let staged = try stage(entry, number: number)
        let built = try SetAsideFingerprint.read(staged)
        if built != recorded, !(ours[entry.path] ?? []).contains(built) {
            // Written down before it goes in, so a later attempt reads it as this tool's own work — a copy that
            // no longer holds what was recorded — and not as somebody's edit to keep.
            ours[entry.path, default: []].append(built)
            try store.writeDurably(ours, to: store.asideURL)
        }
        Self.holdBeforePutBack()
        try kept.append(contentsOf: install(staged, at: entry, number: number, record: record, tree: tree))
        return kept
    }

    /// A test seam, inert unless `SIFT_TEST_HOLD_PUT_BACK` names a file: while that file exists, for up to a minute, a copy built in the store waits before it is put in place.
    ///
    /// So a test can land a save on the path in the window between the copy being built and the move that puts it in place, by waiting on the work rather than racing a poll against it. Nothing outside a test sets the variable, and without it this returns at once.
    private static func holdBeforePutBack() {
        guard let marker = ProcessInfo.processInfo.environment["SIFT_TEST_HOLD_PUT_BACK"], !marker.isEmpty else {
            return
        }
        let deadline = Date().addingTimeInterval(60)
        while access(marker, F_OK) == 0, Date() < deadline {
            usleep(10000)
        }
    }

    /// Builds what `entry` held, in full, in the store — cloned from its copy with its permission bits and a new timestamp, or its link — under `staging/<number>`, and answers that path.
    ///
    /// Built under a `.partial` name first and renamed when done, so a restore killed part-way never leaves a half-copy under the name a later attempt reads as what a swap brought out; anything a killed attempt did leave under that name is taken into the store with the rest, to be looked at.
    private func stage(_ entry: SetAsideRecord.Entry, number: Int) throws -> String {
        try FileManager.default.createDirectory(at: store.staging, withIntermediateDirectories: true)
        let finished = store.staging.appendingPathComponent("\(number)").path
        let partial = finished + ".partial"
        // Only ever this function's own unfinished work, in the store.
        unlink(partial)
        switch entry.worktree {
        case let .file(permissions, _, copy):
            guard copyfile(store.copies.appendingPathComponent(copy).path, partial, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL)) == 0 else {
                throw SetAsideError.store("could not rebuild \(entry.path) from its copy: \(String(cString: strerror(errno)))")
            }
            guard chmod(partial, mode_t(permissions)) == 0, utimes(partial, nil) == 0 else {
                throw SetAsideError.store("could not set the permission bits of \(entry.path): \(String(cString: strerror(errno)))")
            }
        case let .symlink(target):
            guard symlink(target, partial) == 0 else {
                throw SetAsideError.store("could not rebuild the link \(entry.path): \(String(cString: strerror(errno)))")
            }
        case .absent:
            throw SetAsideError.store("\(entry.path) held nothing, and there is nothing to rebuild")
        }
        switch try SetAsideFingerprint.kind(finished) {
        case .absent:
            break
        case .file, .symlink, .directory, .other:
            _ = try displace(finished, number: number, shown: entry.path)
        }
        let code = SetAsideTree.moveExclusively(partial, to: finished)
        guard code == 0 else {
            throw SetAsideError.store("could not stage \(entry.path) in \(store.shownDirectory): \(String(cString: strerror(code)))")
        }
        return finished
    }

    /// Puts the staged `source` at the entry's path without destroying what stands there, and answers what it had to keep aside — a directory standing where the file goes.
    ///
    /// Into an empty path by an exclusive rename, over an occupied one by a swap — what came out goes into the store for the sweep to look at — and, on a volume that cannot swap, by moving what stands there into the store first and then renaming exclusively.
    private func install(_ source: String, at entry: SetAsideRecord.Entry, number: Int, record: SetAsideRecord, tree: SetAsideTree) throws -> [String] {
        let path = tree.absolute(entry.onDisk)
        var kept: [String] = []
        for _ in 0 ..< 50 {
            switch try SetAsideFingerprint.kind(path) {
            case .absent:
                let code = SetAsideTree.moveExclusively(source, to: path)
                if code == 0 {
                    return kept
                }
                guard code == EEXIST else {
                    throw SetAsideError.store("\(entry.path) could not be put back (\(String(cString: strerror(code))))")
                }
            case .directory:
                // Never this tool's: a directory where the file goes is somebody's, and is kept whole.
                try kept.append(keep(path, beside: entry.onDisk, shown: entry.path, record: record, tree: tree))
            case .file, .symlink, .other:
                let code = SetAsideTree.swap(source, path)
                if code == 0 {
                    // `source` now holds what stood at the path.
                    _ = try displace(source, number: number, shown: entry.path)
                    return kept
                }
                switch code {
                case ENOENT:
                    continue
                case ENOTSUP, EINVAL:
                    _ = try displace(path, number: number, shown: entry.path)
                default:
                    throw SetAsideError.store("\(entry.path) could not be put back (\(String(cString: strerror(code))))")
                }
            }
        }
        throw SetAsideError.store("\(entry.path) kept changing while it was being put back, so it was left as it stands")
    }

    /// Moves what stands at `path` into the store under a fresh name, in one exclusive rename; `false` when nothing was there.
    private func displace(_ path: String, number: Int, shown: String) throws -> Bool {
        try FileManager.default.createDirectory(at: store.displaced, withIntermediateDirectories: true)
        while true {
            let destination = store.displaced.appendingPathComponent("\(number)-\(UUID().uuidString.prefix(8))").path
            let code = SetAsideTree.moveExclusively(path, to: destination)
            switch code {
            case 0:
                return true
            case EEXIST:
                continue
            case ENOENT:
                return false
            default:
                throw SetAsideError.store("could not move what stands at \(shown) into \(store.shownDirectory): \(String(cString: strerror(code)))")
            }
        }
    }

    /// The last look before the record goes, at everything the store still holds that came out of the tree, keeping beside its path whatever is not this tool's; answers what it kept.
    ///
    /// What it looks at: files the set-aside moved in, what a swap brought out, what stood at a path that goes back to holding nothing. Whatever is neither what was recorded at its path nor anything this tool left there is kept beside that path, and so is anything moved out of a path left as its writer left it. Everything it leaves is this tool's own, and goes with the store.
    private func sweep(_ record: SetAsideRecord, sparing: Set<String>, ours: [String: [SetAsideFingerprint]], tree: SetAsideTree) throws -> [String] {
        var kept: [String] = []
        for directory in [store.moved, store.displaced, store.staging] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in names.sorted() where !name.hasSuffix(".partial") {
                guard let number = Int(name.split(separator: "-").first ?? ""), record.entries.indices.contains(number) else {
                    continue
                }
                let entry = record.entries[number]
                let path = directory.appendingPathComponent(name).path
                let found = try SetAsideFingerprint.read(path)
                let spared = directory == store.moved && sparing.contains(entry.path)
                guard found != .absent,
                      spared || (found != SetAsideFingerprint(entry.worktree) && !(ours[entry.path] ?? []).contains(found))
                else {
                    continue
                }
                try kept.append(keep(path, beside: entry.onDisk, shown: entry.path, record: record, tree: tree))
            }
        }
        return kept
    }

    /// Moves somebody's bytes beside the path they belong to, or throws saying where they are.
    private func keep(_ source: String, beside relative: String, shown: String, record: SetAsideRecord, tree: SetAsideTree) throws -> String {
        do {
            return try tree.keep(source, beside: relative, id: record.id)
        } catch {
            let place = source.hasPrefix(store.directory.path + "/")
                ? "it is at \(store.shownDirectory)\(source.dropFirst(store.directory.path.count + 1))"
                : "it is still where it was found"
            throw SetAsideError.store("\(shown) changed while it was set aside, and what was found there \(SetAsideError.reason(error)): \(place)")
        }
    }

    /// Puts back every index entry that differs from the one recorded, whatever HEAD now says, and answers the intent-to-add entries still to be made and the spared paths whose entry was left.
    ///
    /// A spared path's entry is left when somebody staged it again after the set-aside wrote it: that staging is theirs, and it is left and said. The intent-to-add entries are made once their files are back.
    private func restoreIndex(_ record: SetAsideRecord, sparing: Set<String>, git: SetAsideGit) throws -> (intents: [String], left: [String]) {
        // Before the index is read, so the gap between reading it and writing it holds no other git.
        try ensureObjects(record, git: git)
        let current = try indexNow(record, git: git)
        let zero = String(repeating: "0", count: record.head.count)
        var indexInfo: [String] = []
        var intents: [String] = []
        var left: [String] = []
        for entry in record.entries where !Self.matches(entry.index, current[entry.path]) {
            if sparing.contains(entry.path), !Self.matches(entry.indexAside, current[entry.path]) {
                left.append(entry.path)
                continue
            }
            switch entry.index {
            case .absent:
                indexInfo.append("0 \(zero)\t\(entry.path)")
            case .intentToAdd:
                if current[entry.path] != nil {
                    indexInfo.append("0 \(zero)\t\(entry.path)")
                }
                intents.append(entry.path)
            case let .entry(staged):
                indexInfo.append("\(staged.mode) \(staged.object)\t\(entry.path)")
            }
        }
        if !indexInfo.isEmpty {
            try git.runWaitingForIndexLock(["update-index", "-z", "--index-info"], input: SetAsideTree.terminated(indexInfo))
        }
        return (intents, left)
    }

    /// Makes sure every staged object the record names is in the object database, rebuilding any a `git gc` pruned from the copy taken before the tree was touched — one `cat-file --batch-check` for all of them, and one `hash-object` for whatever is missing.
    private func ensureObjects(_ record: SetAsideRecord, git: SetAsideGit) throws {
        let objects = Set(record.entries.compactMap { entry -> String? in
            guard case let .entry(staged) = entry.index else {
                return nil
            }
            return staged.object
        }).sorted()
        guard !objects.isEmpty else {
            return
        }
        let answer = try git.run(["cat-file", "--batch-check"], input: Data(objects.map { "\($0)\n" }.joined().utf8))
        let missing = (String(data: answer, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ")
            return fields.count == 2 && fields[1] == "missing" ? String(fields[0]) : nil
        }
        guard !missing.isEmpty else {
            return
        }
        let copies = missing.map { store.blobs.appendingPathComponent($0).path }
        let written = try git.run(["hash-object", "-w", "--no-filters", "--stdin-paths"], input: Data(copies.map { "\($0)\n" }.joined().utf8))
        let names = (String(data: written, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        for (object, name) in zip(missing, names + Array(repeating: "", count: max(0, missing.count - names.count))) where object != name {
            throw SetAsideError.store("the staged object \(object) could not be rebuilt from its copy (it hashed to \(name.isEmpty ? "nothing" : name))")
        }
    }

    /// The commit HEAD names now, when it is not the one the record was made at.
    private func headMove(_ record: SetAsideRecord, git: SetAsideGit) -> String? {
        guard let now = try? git.text(["rev-parse", "--verify", "--quiet", "HEAD"]), !now.isEmpty, now != record.head else {
            return nil
        }
        return now
    }

    private func failure(_ error: SetAsideError, of record: SetAsideRecord, requested: Bool) -> SetAsideError {
        let reasons: [String]
        var locked = false
        switch error {
        case .notRestored:
            return requested ? error.requested : error
        case let .indexLocked(message):
            reasons = [message]
            locked = true
        case let .git(message), let .store(message):
            reasons = [message]
        default:
            reasons = [error.description]
        }
        return .notRestored(SetAsideError.NotRestored(
            reasons: reasons,
            invocation: record.invocation,
            store: store.shownDirectory,
            id: record.id,
            indexLocked: locked,
            requested: requested
        ))
    }
}

// MARK: - The index

extension SetAside {
    /// One stage-0 entry as the index holds it now.
    struct IndexNow: Equatable {
        let mode: String
        let object: String
        let stage: String
    }

    /// The index's entry for every recorded path, read by literal path so no name is taken for a pattern.
    func indexNow(_ record: SetAsideRecord, git: SetAsideGit) throws -> [String: IndexNow] {
        var found: [String: IndexNow] = [:]
        let paths = record.entries.map(\.path)
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start ..< min(start + 500, paths.count)])
            let output = try git.run(["--literal-pathspecs", "ls-files", "-s", "-z", "--"] + chunk)
            for line in output.split(separator: 0) {
                guard let text = String(bytes: line, encoding: .utf8), let tab = text.firstIndex(of: "\t") else {
                    continue
                }
                let fields = text[..<tab].split(separator: " ").map(String.init)
                guard fields.count == 3 else {
                    continue
                }
                found[String(text[text.index(after: tab)...])] = IndexNow(mode: fields[0], object: fields[1], stage: fields[2])
            }
        }
        return found
    }

    /// The object name of an empty blob, in either hash — what an intent-to-add entry carries.
    private static let emptyBlobs: Set<String> = [
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813",
    ]

    static func matches(_ recorded: SetAsideRecord.IndexState, _ now: IndexNow?) -> Bool {
        switch recorded {
        case .absent:
            now == nil
        case let .entry(staged):
            now == IndexNow(mode: staged.mode, object: staged.object, stage: "0")
        case .intentToAdd:
            now.map { $0.stage == "0" && emptyBlobs.contains($0.object) } ?? false
        }
    }

    private static func described(_ now: IndexNow?) -> String {
        guard let now else {
            return "no entry"
        }
        return now.stage == "0" ? "\(now.mode) \(now.object.prefix(12))" : "a conflict (stage \(now.stage))"
    }

    private static func described(_ state: SetAsideRecord.IndexState) -> String {
        switch state {
        case .absent: "no entry"
        case let .entry(staged): "\(staged.mode) \(staged.object.prefix(12))"
        case .intentToAdd: "an intent-to-add entry"
        }
    }
}

// MARK: - The committed change a refusal can point at

private extension SetAside {
    /// The branch's merge-base with the default branch, when the commits since it change a file under the pathspecs — the revision `--since` would set those commits aside to — and `nil` where there is no default branch, `HEAD` is the merge-base, or no commit since it touches them.
    static func committedBase(pathspecs: [String], root: URL, git: SetAsideGit) -> String? {
        let context = GitContext(repoRoot: root)
        guard let head = try? context.head(),
              let defaultBranch = context.defaultBranch(),
              let base = context.mergeBase(defaultBranch.ref, head),
              base != head,
              let changed = try? git.run(["diff", "--name-only", "-z", base, head, "--"] + pathspecs),
              !changed.isEmpty
        else {
            return nil
        }
        return base
    }
}
