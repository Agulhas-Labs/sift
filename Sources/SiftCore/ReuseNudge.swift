//
// Copyright © Agulhas Labs
//

import Foundation

/// A declaration an edit has just added, paired with the existing declaration in its module whose shape is closest by the `similar` ranking.
///
/// What the `PostToolUse` hook tells the model after a write: "this helper may already exist". It is `similar` asked on the model's behalf at the one moment the question is cheapest to act on, so it uses `similar`'s own ranking, floor and exclusion rule unchanged — the only declaration a hit may not be is the added one itself.
public struct ReuseNudge: Sendable {
    /// The declaration the edit added.
    public let added: DeclarationFingerprint
    /// The closest existing declaration, with the shared-callee overlap that admitted it.
    public let hit: SimilarHit

    public init(added: DeclarationFingerprint, hit: SimilarHit) {
        self.added = added
        self.hit = hit
    }

    /// The one line the hook hands the model, in the voice of an answer: what resembles what, where, how closely, and the call that shows the whole ranking.
    public var line: String {
        let found = hit.fingerprint.declaration
        let overlap = SimilarRenderer.formatted(hit.calleeOverlap)
        return "sift: \(added.declaration.qualifiedName) resembles \(found.qualifiedName) — \(found.path):\(found.line) (overlap \(overlap)); "
            + "compare with sift similar \(Self.shellWord(added.declaration.qualifiedName))"
    }
}

public extension ReuseNudge {
    /// How long the hook may spend on one edit before it says nothing.
    static let timeBudget: TimeInterval = 1

    /// The nudges an edit of each of `files` earns, closest first, keyed by the file as given, for every file worked out within `budget`; a file that earns none may be missing.
    ///
    /// Past the budget the work is abandoned where it stands, as the `PreToolUse` hook's in-place answer is: the hook's process ends without it, and an interrupted reindex is SQLite's to roll back. The files worked out by then are handed back all the same, so a patch whose first file earns a nudge draws it however much work its later files would have cost. Any error is an empty answer, never a thrown one — a hook has nothing useful to do with a failure.
    static func findings(forFiles files: [String], atRoot root: String, budget: TimeInterval = timeBudget) -> [String: [ReuseNudge]] {
        findings(forFiles: files, atRoot: root, budget: budget) { paths, repoRoot in
            await SimilarSearch.scan(paths: paths, repoRoot: repoRoot)
        }
    }

    /// Each declaration in `path` whose name `before` lacks, paired with its best hit among `fingerprints`, closest first.
    ///
    /// Split out so the choice is exercisable over sources held in memory. A test function draws no nudge toward another test function, and no declaration draws one toward a declaration its own body calls. A declaration too thin to rank, or with nothing at `similar`'s floor whose shared callees weigh enough (`SimilarityScore.nudgeEvidenceFloor`, and `nudgeTestEvidenceFloor` for a test), earns nothing.
    static func closest(addedTo path: String, before: Set<String>, among fingerprints: [DeclarationFingerprint]) -> [ReuseNudge] {
        let added = fingerprints.filter { fingerprint in
            fingerprint.declaration.path == path
                && !before.contains(fingerprint.declaration.qualifiedName)
                && fingerprint.callees.count >= SimilarityScore.minimumCallees
        }
        let nonTests = fingerprints.filter { !$0.isTest }
        let nudges = added.compactMap { subject -> ReuseNudge? in
            // A test function is never nudged toward another: sibling tests share their callees by construction. Dropping them before the ranking lets the best hit that is not a test still be the one named.
            let pool = subject.isTest ? nonTests : fingerprints
            // A declaration the added one calls is what it is built on, not a copy of it: a test and the helper it drives share callees because one calls the other.
            let candidates = pool.filter { !subject.callees.contains($0.declaration.baseName) }
            guard case let .ranked(_, hits, _) = SimilarSearch.rank(subject: subject, among: candidates) else { return nil }
            // Overlap is a fraction, and two bodies that share only `map` and `joined` reach a high one on almost no evidence: the nudge also wants the shared callees to weigh something, more of it for a test, whose bodies all share the lookup-and-expect calls.
            let evidence = subject.isTest ? SimilarityScore.nudgeTestEvidenceFloor : SimilarityScore.nudgeEvidenceFloor
            guard let best = hits.first(where: { $0.sharedEvidence >= evidence }) else { return nil }
            return ReuseNudge(added: subject, hit: best)
        }
        // Score first, then the added declaration's line: the same edit must nudge the same way on every run.
        return nudges.sorted { left, right in
            guard left.hit.score == right.hit.score else { return left.hit.score > right.hit.score }
            return left.added.declaration.line < right.added.declaration.line
        }
    }
}

extension ReuseNudge {
    /// The nudges as the public form works them out, with `scan` in place of `similar`'s scan of a module's paths: the seam a test counts or holds the scans through.
    ///
    /// The closure passed last runs once the work has started and before the budget's clock does, so a test can start the clock at a point in the work of its choosing rather than race it.
    static func findings(
        forFiles files: [String],
        atRoot root: String,
        budget: TimeInterval,
        scan: @escaping @Sendable ([String], URL) async -> [DeclarationFingerprint],
        beforeTheBudget: () -> Void = {}
    ) -> [String: [ReuseNudge]] {
        let box = FindingsBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            try? await findings(forFiles: files, atRoot: root, scan: scan) { file, nudges in box.store(nudges, for: file) }
            finished.signal()
        }
        beforeTheBudget()
        _ = finished.wait(timeout: .now() + budget)
        return box.value
    }

    /// Works out the nudges an edit of each of `files` earns, closest first, handing each file's to `found` as soon as they are known, in the order of `files`.
    ///
    /// **New means new to the file's index record**: the function-like declarations with a body whose qualified name the index did not hold for the file before this call brings it up to date. Every file's record is read before that one refresh, which brings every dirty file in the repository up to date: read after it, a function another file of the same edit added would count as one the index already held. A file whose record gained no name adds nothing, and its module is not scanned for it: a comment-only change to a file of another module costs nothing. A file the index never held adds nothing — a first write of a whole file is not a reuse question, and every declaration in it would otherwise count as just written. A file whose record before or after this call carries a parse error adds nothing either — a broken parse can be missing declarations that are genuinely still there, and everything the reindex finds would then read as newly added. The candidates are every indexed file in the same module, read from the working tree as `similar` reads them.
    static func findings(
        forFiles files: [String],
        atRoot root: String,
        scan: @Sendable ([String], URL) async -> [DeclarationFingerprint],
        found: (String, [ReuseNudge]) -> Void
    ) async throws {
        let engine = try SiftEngine(directory: URL(fileURLWithPath: root))
        let edited = files.compactMap { file in relativePath(of: file, under: engine.repoRoot.path).map { (file: file, path: $0) } }
        let before = try edited.map { try declaredNames(inFile: $0.path, of: engine.store) }
        try await engine.ensureFresh()
        let inventory = try engine.store.fileInventory().values
        var scans: [String: [DeclarationFingerprint]] = [:]
        for (edit, before) in zip(edited, before) {
            guard let before, let after = try declaredNames(inFile: edit.path, of: engine.store), !after.isSubset(of: before),
                  let row = try engine.store.fileRow(path: edit.path)
            else {
                continue
            }
            let fingerprints: [DeclarationFingerprint]
            if let scanned = scans[row.module] {
                fingerprints = scanned
            } else {
                fingerprints = await scan(inventory.filter { $0.module == row.module }.map(\.path), engine.repoRoot)
                scans[row.module] = fingerprints
            }
            found(edit.file, closest(addedTo: edit.path, before: before, among: fingerprints))
        }
    }
}

private extension ReuseNudge {
    /// What the detached work hands back, file by file as each is worked out, however far it got by the time the budget is spent.
    ///
    /// Unchecked because the lock is the ordering: the detached work may still be storing a file when the waiting thread reads what is there.
    final class FindingsBox: @unchecked Sendable {
        private let gate = NSLock()
        private var stored: [String: [ReuseNudge]] = [:]

        var value: [String: [ReuseNudge]] {
            gate.withLock { stored }
        }

        func store(_ nudges: [ReuseNudge], for file: String) {
            gate.withLock { stored[file] = nudges }
        }
    }

    /// Every declaration's name in `path` as the index holds it, qualified by its enclosing types as a fingerprint's is, or `nil` when the index holds no record of the file, or the record it holds carries a parse error.
    ///
    /// A parse error leaves the parser's recovered tree short of what the file actually declares, so a name genuinely present can be missing from `before` — and everything the reindex later finds would then read as newly added. `nil` here reads the same way a first write of the file does: nothing to compare against, so the caller says nothing.
    static func declaredNames(inFile path: String, of store: IndexStore) throws -> Set<String>? {
        guard let row = try store.fileRow(path: path), row.parseErrorCount == 0 else { return nil }
        let rows = try store.symbols(inFile: path)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(rows.map { row in
            var names = [row.name]
            var parent = row.parentID
            while let id = parent, let container = byID[id] {
                names.insert(container.name, at: 0)
                parent = container.parentID
            }
            return names.joined(separator: ".")
        })
    }

    /// `name` as one shell word: bare where it is only letters, digits, dots and underscores, single-quoted otherwise.
    static func shellWord(_ name: String) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return bare ? name : "'\(name)'"
    }
}

extension ReuseNudge {
    /// `file` relative to `root`, both canonicalised at the comparison, or `nil` when it lies outside.
    static func relativePath(of file: String, under root: String) -> String? {
        let prefix = CanonicalPath.of(root) + "/"
        let canonical = CanonicalPath.of(file)
        guard canonical.hasPrefix(prefix) else { return nil }
        return String(canonical.dropFirst(prefix.count))
    }
}

private extension StructuralMatch {
    /// The name a call to this declaration is written with: `hook` for `Fixture.hook(path:session:)`.
    var baseName: String {
        let head = qualifiedName.prefix { $0 != "(" }
        return String(head.split(separator: ".").last ?? head)
    }
}
