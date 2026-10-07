//
// Copyright © Agulhas Labs
//

import Foundation

/// `diff`'s gathering step: a range in, `DiffRenderer`'s answer out.
///
/// A standalone type rather than more of `SiftEngine` itself, the same split `AffectedRenderer`/`WhereRenderer` already keep — `SiftEngine.diff` constructs one with its own `git`/`enumerator`/`store`/`repoRoot` and calls straight through.
struct DiffGatherer {
    let git: GitContext
    let enumerator: FileEnumerator
    let store: IndexStore
    let repoRoot: URL
    /// The resolver's project directories, handed to the reaching-tests walk so another project's test files stay out of it.
    let projectDirectories: [String]

    /// Files whose two sides are read in one `git cat-file` batch and compared before the next batch is read — the bound on how much source is ever held at once.
    static var batchSize: Int {
        64
    }

    /// Resolves the range's change set, compares both sides of every Swift file the index would hold, and gathers what the rest of the answer needs.
    ///
    /// Parsing never touches the persisted index — it holds one snapshot of the current working tree, which cannot answer for an arbitrary historical revision — so each side of each touched file is read directly (one `git cat-file --batch` per batch of files, or disk when the near side is the working tree) and parsed fresh, one file at a time, its tree discarded before the next and its sources discarded once compared (Docs/Design.md §2).
    func diff(options: DiffOptions, semantic: SemanticInput) async throws -> DiffRenderer.Output {
        let range = options.range
        let (allChanges, untrackedNow) = try Self.merged(changeList(for: range))
        let untracked = range.to == .workingTree ? try Set(git.untrackedFiles()) : []
        let stats = try lineStats(range: range, changes: allChanges, untracked: untracked, untrackedNow: untrackedNow)

        var brokenDown: [GitContext.Change] = []
        var notBrokenDown: [DiffRenderer.SkippedFile] = []
        var nonSwift: [DiffRenderer.NonSwiftFile] = []
        // The trees are listed only where a Swift path is tested against them.
        let links = try allChanges.contains { $0.path.hasSuffix(".swift") } ? RangeLinks(from: range.from, to: range.to, git: git) : nil
        for change in allChanges {
            let isUntrackedNow = untrackedNow.contains(change.path)
            guard change.path.hasSuffix(".swift"), let links else {
                nonSwift.append(DiffRenderer.NonSwiftFile(path: change.path, renamedFrom: change.renamedFrom, stat: stats[change.path], untrackedNow: isUntrackedNow))
                continue
            }
            if let exclusion = links.exclusion(of: change, enumerator: enumerator) {
                notBrokenDown.append(DiffRenderer.SkippedFile(path: change.path, reason: exclusion.reason, stat: stats[change.path], untrackedNow: isUntrackedNow))
            } else {
                brokenDown.append(change)
            }
        }

        // Sorted, because the files are compared concurrently and land in whatever order they finish — and an
        // answer must not vary between two runs over the same range.
        let files = try await compare(brokenDown, range: range, links: links, stats: stats, untrackedNow: untrackedNow, member: options.member).sorted { $0.path < $1.path }
        let summaryPage = options.member == nil && options.offset == 0
        let callers = summaryPage ? try await callerReports(files: files, semantic: semantic) : []
        let tests = summaryPage && !brokenDown.isEmpty ? try await reachingTests(brokenDown, excludedByConfig: notBrokenDown, range: range, semantic: semantic) : nil

        return try DiffRenderer.render(DiffRenderer.Input(
            range: range,
            files: files,
            notBrokenDown: notBrokenDown,
            nonSwift: nonSwift,
            callers: callers,
            workingTreeIsAfterSide: callers.isEmpty ? false : workingTreeIsAfterSide(range),
            tests: tests,
            options: options,
            rawDiffBytes: rawDiffByteCount(range: range, untracked: allChanges.filter { untracked.contains($0.path) }.map(\.path)),
            axis: Self.axis(of: tests, judging: callers.flatMap(\.staleFiles))
        ))
    }

    /// The header's axis: the reaching tests' own, counting once more each file the callers' wrapper listings relied on that is newer than the build.
    static func axis(of tests: AffectedRenderer.Output?, judging staleFiles: [String]) -> SemanticAxis {
        let base = tests?.axis ?? .syntacticOnly
        let extra = Set(staleFiles).subtracting(tests?.newerFiles ?? [])
        guard !extra.isEmpty else { return base }
        return switch base {
        case let .stale(newer, deleted): .stale(newerFiles: newer + extra.count, deletedOccurrenceFiles: deleted)
        case .fresh, .unresolved, .partial: .stale(newerFiles: extra.count, deletedOccurrenceFiles: 0)
        default: base
        }
    }

    /// One touched file compared exactly as a range's files are — the unit the gatherer runs per file, for a caller holding both sides' bytes.
    static func fileDiff(_ change: GitContext.Change, old: Data?, new: Data?, stat: GitContext.LineStat? = nil, member: String? = nil) -> FileDiff {
        compare(Pending(change: change, old: old, new: new, stat: stat, untrackedNow: false), member: member)
    }
}

private extension DiffGatherer {
    /// One file's two sides as read, waiting to be compared.
    struct Pending: Sendable {
        let change: GitContext.Change
        let old: Data?
        let new: Data?
        let stat: GitContext.LineStat?
        let untrackedNow: Bool
    }

    /// The change set `diff` reads from — every file, not only `.swift` ones, since every touched file is listed somewhere.
    func changeList(for range: DiffRange) throws -> [GitContext.Change] {
        switch range.to {
        case .workingTree: try git.dirtyFiles()
        case let .revision(rev): try git.changedFiles(from: range.from, to: rev)
        }
    }

    /// The change list with each path once: a path `git status` reports both as a staged deletion and as untracked — `git rm --cached` — is one file, still on disk, and its paths are returned alongside.
    static func merged(_ changes: [GitContext.Change]) -> (changes: [GitContext.Change], untrackedNow: Set<String>) {
        let isDeletion: (GitContext.Change) -> Bool = { change in
            if case .deleted = change.kind {
                return true
            }
            return false
        }
        let repeated = Dictionary(grouping: changes, by: \.path).filter { $0.value.count > 1 }
        let untrackedNow = Set(repeated.filter { $0.value.contains(where: isDeletion) && !$0.value.allSatisfy(isDeletion) }.keys)
        var seen: Set<String> = []
        let merged = changes.filter { change in
            if untrackedNow.contains(change.path), isDeletion(change) {
                return false
            }
            return seen.insert(change.path).inserted
        }
        return (merged, untrackedNow)
    }

    /// Line counts for every touched path, keyed by its after-side path.
    ///
    /// `git diff --numstat` covers every tracked change on both endpoints; its one gap is an untracked file in the working tree, which it never lists at all, so that one case is read straight off disk — as binary when git would call it binary. A file deleted in the index but still on disk is counted as what it is to this answer — `HEAD`'s copy against the one on disk — not as the deletion git's own counts describe.
    func lineStats(range: DiffRange, changes: [GitContext.Change], untracked: Set<String>, untrackedNow: Set<String>) throws -> [String: GitContext.LineStat] {
        var stats: [String: GitContext.LineStat] = switch range.to {
        case .workingTree: try git.lineStats(from: range.from)
        case let .revision(rev): try git.lineStats(from: range.from, to: rev)
        }
        for change in changes where untrackedNow.contains(change.path) {
            let old = try git.blobs([(rev: range.from, path: change.path)]).first.flatMap(\.self)
            let new = try? Data(contentsOf: repoRoot.appendingPathComponent(change.path))
            stats[change.path] = Self.stat(old: old, new: new)
        }
        for change in changes where stats[change.path] == nil && untracked.contains(change.path) {
            guard let data = try? Data(contentsOf: repoRoot.appendingPathComponent(change.path)) else { continue }
            stats[change.path] = Self.addedStat(of: data)
        }
        return stats
    }

    /// Every Swift file the index would hold, both sides read in batches and compared as each batch lands.
    ///
    /// The files of a batch are compared concurrently, at most one per core in flight, the way the indexer parses — each comparison still parses one file at a time and discards its trees before returning. A side `links` records as a symbolic link is compared as holding nothing, since its bytes are a target's path rather than Swift source.
    func compare(_ changes: [GitContext.Change], range: DiffRange, links: RangeLinks?, stats: [String: GitContext.LineStat], untrackedNow: Set<String>, member: String?) async throws -> [FileDiff] {
        var files: [FileDiff] = []
        var start = 0
        while start < changes.count {
            let batch = Array(changes[start ..< min(start + Self.batchSize, changes.count)])
            start += Self.batchSize
            var requests = batch.map { (rev: range.from, path: $0.renamedFrom ?? $0.path) }
            if case let .revision(rev) = range.to {
                requests += batch.map { (rev: rev, path: $0.path) }
            }
            let blobs = try git.blobs(requests)
            let pending = batch.enumerated().map { offset, change in
                let sides = links?.linkSides(of: change, enumerator: enumerator) ?? (before: false, after: false)
                let newData: Data? = switch range.to {
                case _ where sides.after: nil
                case .workingTree: try? Data(contentsOf: repoRoot.appendingPathComponent(change.path))
                case .revision: blobs[batch.count + offset]
                }
                let oldData = sides.before ? nil : blobs[offset]
                return Pending(change: change, old: oldData, new: newData, stat: stats[change.path], untrackedNow: untrackedNow.contains(change.path))
            }
            files += await Self.compareConcurrently(pending, member: member)
        }
        return files
    }

    static func compareConcurrently(_ pending: [Pending], member: String?) async -> [FileDiff] {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var results: [FileDiff] = []
        results.reserveCapacity(pending.count)
        await withTaskGroup(of: FileDiff.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0
            while inFlight < cores, let next = iterator.next() {
                group.addTask { compare(next, member: member) }
                inFlight += 1
            }
            for await file in group {
                results.append(file)
                if let next = iterator.next() {
                    group.addTask { compare(next, member: member) }
                }
            }
        }
        return results
    }

    /// One file compared — keeping a body only on the declaration `member` names, never every body in the range.
    static func compare(_ pending: Pending, member: String?) -> FileDiff {
        let change = pending.change
        let status: FileDiff.Status = if pending.untrackedNow {
            .untrackedNow
        } else if let from = change.renamedFrom {
            .renamed(from: from)
        } else if pending.old == nil {
            .added
        } else if pending.new == nil {
            .deleted
        } else {
            .modified
        }
        let keepsBody: (DeclarationChange) -> Bool = if let member {
            { DiffMemberRenderer.accepts(member, path: change.path, change: $0) }
        } else {
            { _ in false }
        }
        return FileDiff.compare(path: change.path, status: status, lineStat: pending.stat, bytes: (pending.old, pending.new), keepsBody: keepsBody)
    }

    /// Callers of every member the range removed, changed the signature of, or changed the effective access of.
    func callerReports(files: [FileDiff], semantic: SemanticInput) async throws -> [DiffCallers.Report] {
        let targets = files.flatMap { file in
            file.changes.compactMap { change -> DiffCallers.Target? in
                guard DiffCallers.isCallable(change.symbolKind) else { return nil }
                guard change.kind == .removed || (change.kind == .changed && (change.signatureChanged || change.oldAccess != nil)) else { return nil }
                guard let pin = change.addressLine else { return nil }
                return DiffCallers.Target(label: change.label, name: change.name, kind: change.symbolKind, path: file.path, line: pin.line, removed: change.kind == .removed)
            }
        }
        guard !targets.isEmpty else { return [] }
        return try await DiffCallers(store: store, repoRoot: repoRoot, enumerator: enumerator).reports(for: targets, semantic: semantic)
    }

    /// Whether the working tree the callers are read from is this range's after side, as far as Swift is concerned: the default range, or one ending at the commit `HEAD` names with no Swift file dirty.
    func workingTreeIsAfterSide(_ range: DiffRange) -> Bool {
        guard case let .revision(rev) = range.to else { return true }
        guard let after = git.shortHash(rev), after == git.shortHash("HEAD") else { return false }
        return (try? git.dirtySwiftFiles().isEmpty) ?? false
    }

    /// The tests `affected` finds reaching the changed files, for the same change set.
    func reachingTests(
        _ changes: [GitContext.Change],
        excludedByConfig skipped: [DiffRenderer.SkippedFile],
        range: DiffRange,
        semantic: SemanticInput
    ) async throws -> AffectedRenderer.Output {
        let scanner = NameMentionScanner(repoRoot: repoRoot, enumerator: enumerator)
        var renderer = AffectedRenderer(store: store, repositoryRoot: repoRoot, projectDirectories: projectDirectories)
        renderer.mentions = { await scanner.mentions(of: $0) }
        return try await renderer.render(
            changes: changes,
            excludedByConfig: skipped.map(\.path).filter { enumerator.isNarrowedAwayByConfig(relativePath: $0) },
            semantic: semantic,
            options: AffectedOptions(range: range.affectedRange)
        )
    }

    /// The raw `git diff` the answer is priced against — in working-tree mode plus the untracked files it includes, counted as the added-file diff git prints for one: its header, then every line with a `+` before it.
    func rawDiffByteCount(range: DiffRange, untracked: [String]) throws -> Int {
        switch range.to {
        case let .revision(rev):
            return try git.diffByteCount(from: range.from, to: rev)
        case .workingTree:
            var total = try git.diffByteCount(from: range.from)
            for path in untracked {
                guard let data = try? Data(contentsOf: repoRoot.appendingPathComponent(path)) else { continue }
                total += Self.addedDiffBytes(path: path, data: data)
            }
            return total
        }
    }

    /// Added and removed line counts between two sides read directly, as `git diff --numstat` would count them.
    static func stat(old: Data?, new: Data?) -> GitContext.LineStat {
        if [old, new].contains(where: { $0.map(isBinary) ?? false }) {
            return GitContext.LineStat(added: 0, removed: 0, binary: true)
        }
        let hunks = LineDiff.hunks(old: old.map(LineDiff.lines) ?? [], new: new.map(LineDiff.lines) ?? [])
        return GitContext.LineStat(added: hunks.reduce(0) { $0 + $1.new.count }, removed: hunks.reduce(0) { $0 + $1.old.count }, binary: false)
    }

    static func addedStat(of data: Data) -> GitContext.LineStat {
        guard !isBinary(data), let text = String(data: data, encoding: .utf8) else {
            return GitContext.LineStat(added: 0, removed: 0, binary: true)
        }
        return GitContext.LineStat(added: SourcePassthrough.lines(of: text).count, removed: 0, binary: false)
    }

    /// git's own test: a NUL byte in the first 8000 bytes makes a file binary.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// The bytes `git diff` prints for a new file: its header, then — for text — one hunk carrying every line with a `+` before it, and git's marker when the last line has no newline.
    static func addedDiffBytes(path: String, data: Data) -> Int {
        let header = "diff --git a/\(path) b/\(path)\nnew file mode 100644\nindex 0000000..0000000\n"
        guard !isBinary(data), String(data: data, encoding: .utf8) != nil else {
            return (header + "Binary files /dev/null and b/\(path) differ\n").utf8.count
        }
        let lines = LineDiff.lines(of: data)
        guard !lines.isEmpty else { return header.utf8.count }
        // git writes a one-line hunk's length as `+1`, not `+1,1`.
        let hunk = "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n"
        let unterminated = data.last == 0x0A ? 0 : "\n\\ No newline at end of file\n".utf8.count
        return header.utf8.count + hunk.utf8.count + lines.reduce(0) { $0 + 1 + $1.count } + unterminated
    }
}

extension GitContext.Change {
    /// The path a rename moved this file from, `nil` for anything else.
    var renamedFrom: String? {
        if case let .renamed(from) = kind {
            return from
        }
        return nil
    }
}
