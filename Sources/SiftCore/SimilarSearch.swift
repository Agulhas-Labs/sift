//
// Copyright © Agulhas Labs
//

import Foundation

/// Ranks the repository's declarations by how close their syntactic shape is to one target's.
///
/// Reads the **working tree**, not the index, for the same reason `search` does (Docs/Design.md §3): the axes it compares — a body's calls, its control flow, its written types — are not stored, and storing them would buy nothing a re-parse does not already give while adding an invalidation problem where there is none. So it has no staleness axis and never refuses.
///
/// Every file is parsed once, its fingerprints extracted inside that call, and its tree dropped there — the rule that no syntax tree survives its file, kept at the only place in this answer where one exists.
struct SimilarSearch {
    let repoRoot: URL
    let enumerator: FileEnumerator

    func run(target: String) async -> SimilarAnswer {
        let paths = enumerator.swiftFiles()
        let fingerprints = await Self.scan(paths: paths, repoRoot: repoRoot)
        return Self.answer(target: target, fingerprints: fingerprints, filesScanned: paths.count)
    }

    /// The whole answer given the fingerprints, with no filesystem in it.
    ///
    /// Split out so the ranking is exercisable over sources held in memory: every property that decides what an answer means — the rarity weighting, the floor, the thin-target refusal, the target's exclusion from its own results, the tie order — is a property of this function, and a test that had to lay a repository on disk to reach it would be testing the enumerator instead.
    static func answer(target: String, fingerprints: [DeclarationFingerprint], filesScanned: Int) -> SimilarAnswer {
        let census = SimilarAnswer.Census(filesScanned: filesScanned, candidates: fingerprints.count)
        let outcome: SimilarAnswer.Outcome = switch SimilarTarget.resolve(target, among: fingerprints) {
        case .missing: .unresolved
        case let .ambiguous(candidates): .ambiguous(candidates)
        case let .one(subject): rank(subject: subject, among: fingerprints)
        }
        return SimilarAnswer(target: target, census: census, outcome: outcome)
    }

    /// The ranking, or the refusal a body too thin to compare earns instead.
    static func rank(subject: DeclarationFingerprint, among fingerprints: [DeclarationFingerprint]) -> SimilarAnswer.Outcome {
        guard subject.callees.count >= SimilarityScore.minimumCallees else { return .thin(subject: subject) }
        let rarity = CalleeRarity(fingerprints: fingerprints)
        let cleared = fingerprints
            .lazy
            // A candidate sharing no callee has an overlap of zero, under any floor, so it is dropped before the full score is paid for.
            .filter { !$0.callees.isDisjoint(with: subject.callees) && !$0.isSameDeclaration(as: subject) }
            .map { SimilarityScore.hit(for: $0, against: subject, rarity: rarity) }
            .filter { $0.calleeOverlap >= SimilarityScore.calleeFloor }
            .sorted { left, right in
                // Score first, then path and line: a tie between two equally close shapes must land the same way on every run, or a second look at the same question reads as a change in the codebase.
                guard left.score == right.score else { return left.score > right.score }
                return (left.fingerprint.declaration.path, left.fingerprint.declaration.line)
                    < (right.fingerprint.declaration.path, right.fingerprint.declaration.line)
            }
        return .ranked(subject: subject, hits: Array(cleared.prefix(SimilarityScore.resultCap)), above: cleared.count)
    }

    /// Every file's fingerprints, parsed in parallel and ordered by path then line.
    static func scan(paths: [String], repoRoot: URL) async -> [DeclarationFingerprint] {
        guard !paths.isEmpty else { return [] }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var collected: [DeclarationFingerprint] = []
        await withTaskGroup(of: [DeclarationFingerprint].self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask { fingerprints(at: path, rootPath: rootPath) }
                inFlight += 1
            }
            for await found in group {
                collected.append(contentsOf: found)
                if let path = iterator.next() {
                    group.addTask { fingerprints(at: path, rootPath: rootPath) }
                }
            }
        }
        return collected.sorted { ($0.declaration.path, $0.declaration.line) < ($1.declaration.path, $1.declaration.line) }
    }

    /// One file's fingerprints; an unreadable or non-UTF-8 file contributes none rather than failing the query.
    private static func fingerprints(at path: String, rootPath: String) -> [DeclarationFingerprint] {
        guard let data = FileManager.default.contents(atPath: rootPath + "/" + path),
              let source = String(data: data, encoding: .utf8) else { return [] }
        return FingerprintScanner.fingerprints(in: source, path: path)
    }
}
