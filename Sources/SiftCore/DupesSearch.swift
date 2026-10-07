//
// Copyright © Agulhas Labs
//

import Foundation

/// Finds groups of near-duplicate bodies across a tree: `similar`'s comparison run over every pair worth comparing instead of against one target.
///
/// Reads the working tree through `SimilarSearch.scan`, so it shares `similar`'s fingerprints, its rarity weighting and its score, and has no staleness axis for the same reason. What it adds is which pairs get compared — an inverted index of callee to declarations, so the cost follows the pairs that share a rare call rather than the square of the tree — and a union-find that reads `A~B, B~C` as one group of three.
struct DupesSearch {
    let repoRoot: URL
    let enumerator: FileEnumerator

    func run(scope: [String], options: DupesOptions = DupesOptions()) async -> DupesAnswer {
        let prefixes = Self.prefixes(scope, rootPath: repoRoot.path)
        let paths = enumerator.swiftFiles().filter { Self.isUnder($0, prefixes: prefixes) }
        let fingerprints = await SimilarSearch.scan(paths: paths, repoRoot: repoRoot)
        return Self.answer(scope: scope, fingerprints: fingerprints, filesScanned: paths.count, options: options)
    }

    /// The whole audit given the fingerprints, with no filesystem in it.
    static func answer(scope: [String], fingerprints: [DeclarationFingerprint], filesScanned: Int, options: DupesOptions = DupesOptions()) -> DupesAnswer {
        // Two pricings, as the candidate pairs have two fan-out counts: a pair of production declarations is priced against production code alone, where the tests' many calls to what production calls would otherwise price its evidence as common.
        let everything = CalleeRarity(fingerprints: fingerprints)
        let production = CalleeRarity(fingerprints: fingerprints.filter { !DupesRanking.isTestOrPreview($0) })
        let calling = fingerprints.filter { $0.callees.count >= SimilarityScore.minimumCallees }
        let sized = calling.filter { DupesRanking.span(of: $0) >= DupesRanking.sizeFloor }
        let compared = options.testCode == .leftOut ? sized.filter { !DupesRanking.isTestOrPreview($0) } : sized
        let census = DupesAnswer.Census(
            filesScanned: filesScanned,
            withBody: fingerprints.count,
            compared: compared.count,
            underSizeFloor: calling.count - sized.count,
            testCodeLeftOut: sized.count - compared.count,
            fanOutExcluded: fanOutExcludedCount(among: compared)
        )
        let isTestCode = compared.map(DupesRanking.isTestOrPreview)
        let pairs = candidatePairs(among: compared).compactMap { pair -> ScoredPair? in
            let (left, right) = (compared[pair.low], compared[pair.high])
            guard !encloses(left, right) else { return nil }
            let rarity = isTestCode[pair.low] || isTestCode[pair.high] ? everything : production
            // The score is symmetric — weighted Jaccard, a common subsequence over both lengths, plain Jaccard — so one direction is the pair's score.
            let hit = SimilarityScore.hit(for: right, against: left, rarity: rarity)
            guard hit.calleeOverlap >= options.minimumOverlap,
                  sharedWeight(left, right, rarity: rarity) >= SimilarityScore.dupesEvidenceFloor * rarity.singleWeight else { return nil }
            return ScoredPair(low: pair.low, high: pair.high, hit: hit)
        }
        let clustering = DupesClustering(pairs: pairs)
        let lastTier = options.testCode == .rankedLast
        let groups = clustering.groups.map { indices in
            group(indices, among: compared, scores: clustering.scores, rarity: indices.contains { isTestCode[$0] } ? everything : production)
        }.sorted { left, right in
            if lastTier, left.isTestOrPreview != right.isTestOrPreview {
                return !left.isTestOrPreview
            }
            if (left.copies == .none) != (right.copies == .none) {
                return left.copies != .none
            }
            guard left.weight == right.weight else { return left.weight > right.weight }
            guard left.bestScore == right.bestScore else { return left.bestScore > right.bestScore }
            return (left.members[0].declaration.path, left.members[0].declaration.line)
                < (right.members[0].declaration.path, right.members[0].declaration.line)
        }
        return DupesAnswer(
            scope: scope,
            options: options,
            census: census,
            groups: Array(groups.dropFirst(options.offset).prefix(SimilarityScore.resultCap)),
            totalGroups: groups.count,
            testOrPreviewGroups: groups.count(where: \.isTestOrPreview),
            strays: clustering.strays
        )
    }

    /// Every pair of indices that shares at least one callee named by no more than `SimilarityScore.dupesFanOutBound` declarations — counted among production code alone for a pair of production declarations, among everything compared for any other pair.
    ///
    /// Counted twice because test code calls what production code calls, many times over: on this repository's own tree the tests pushed `contentsOfDirectory` and `fileExists` past the bound, and a planted copy of a production helper was never compared with its original, though `dupes Sources` paired them at 1.00.
    static func candidatePairs(among compared: [DeclarationFingerprint]) -> Set<IndexPair> {
        var pairs = Set<IndexPair>()
        for postings in [postings(of: compared), postings(of: compared, productionOnly: true)] {
            for members in postings.values where members.count > 1 && members.count <= SimilarityScore.dupesFanOutBound {
                for (offset, low) in members.enumerated() {
                    for high in members[(offset + 1)...] {
                        pairs.insert(IndexPair(low: low, high: high))
                    }
                }
            }
        }
        return pairs
    }

    /// How many of `compared` named no callee within the fan-out bound, so every one of theirs was too common to propose a pair.
    ///
    /// Shares its denominators with `candidatePairs`: a production declaration is bounded by the production postings, the smaller of the two, and any other by the postings of everything compared.
    static func fanOutExcludedCount(among compared: [DeclarationFingerprint]) -> Int {
        let (all, production) = (postings(of: compared), postings(of: compared, productionOnly: true))
        return compared.count { fingerprint in
            let counts = DupesRanking.isTestOrPreview(fingerprint) ? all : production
            return fingerprint.callees.allSatisfy { (counts[$0]?.count ?? 0) > SimilarityScore.dupesFanOutBound }
        }
    }

    /// Callee to the indices of the compared declarations naming it, over production code alone or over everything.
    private static func postings(of compared: [DeclarationFingerprint], productionOnly: Bool = false) -> [String: [Int]] {
        var postings: [String: [Int]] = [:]
        for (index, fingerprint) in compared.enumerated() where !productionOnly || !DupesRanking.isTestOrPreview(fingerprint) {
            for callee in fingerprint.callees {
                postings[callee, default: []].append(index)
            }
        }
        return postings
    }

    /// The summed rarity weight of the callees two declarations share, added in name order so the same pair sums to the same rounding on every run.
    private static func sharedWeight(_ left: DeclarationFingerprint, _ right: DeclarationFingerprint, rarity: CalleeRarity) -> Double {
        left.callees.intersection(right.callees).sorted().reduce(0) { $0 + rarity.weight(of: $1) }
    }

    /// Whether one declaration lies inside the other, as a local function lies inside the body whose fingerprint already counts its calls.
    private static func encloses(_ left: DeclarationFingerprint, _ right: DeclarationFingerprint) -> Bool {
        let (first, second) = (left.declaration, right.declaration)
        guard first.path == second.path else { return false }
        return (first.line <= second.line && second.endLine <= first.endLine)
            || (second.line <= first.line && first.endLine <= second.endLine)
    }

    /// One group of compared indices, every pair of which cleared the floors, with its closest and weakest pairs, what folding it saves, and the callees its members share.
    private static func group(_ indices: [Int], among compared: [DeclarationFingerprint], scores: [IndexPair: SimilarHit], rarity: CalleeRarity) -> DupesAnswer.Group {
        let links = indices.enumerated().flatMap { offset, low in
            indices[(offset + 1)...].compactMap { high in scores[IndexPair(low: low, high: high)].map { ScoredPair(low: low, high: high, hit: $0) } }
        }
        let members = indices.map { compared[$0] }
        // Best by score, then by the pair's own indices, so a tie picks the same pair on every run.
        let best = links.min { left, right in
            left.hit.score == right.hit.score ? (left.low, left.high) < (right.low, right.high) : left.hit.score > right.hit.score
        }
        let common = members.dropFirst().reduce(members[0].callees) { $0.intersection($1.callees) }
        let pairwise = links.reduce(into: Set<String>()) { $0.formUnion(compared[$1.low].callees.intersection(compared[$1.high].callees)) }
        return DupesAnswer.Group(
            members: members,
            bestScore: best?.hit.score ?? 0,
            bestOverlap: best?.hit.calleeOverlap ?? 0,
            weakestOverlap: links.map(\.hit.calleeOverlap).min() ?? 0,
            weakestScore: links.map(\.hit.score).min() ?? 0,
            duplicatedLines: DupesRanking.duplicatedLines(of: members),
            isTestOrPreview: members.allSatisfy(DupesRanking.isTestOrPreview),
            copies: DupesRanking.copies(among: members),
            sharedCallees: SimilarityScore.rarestFirst(common.isEmpty ? pairwise : common, rarity: rarity),
            sharedByEveryMember: !common.isEmpty
        )
    }

    /// The scope as repo-relative prefixes, where an empty prefix — from `.` or the root itself — is the whole tree.
    private static func prefixes(_ scope: [String], rootPath: String) -> [String] {
        scope.map { path in
            var trimmed = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            while trimmed.hasPrefix("./") {
                trimmed.removeFirst(2)
            }
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            return trimmed == "." || path == rootPath ? "" : trimmed
        }
    }

    /// Whether a repo-relative file path is one of `prefixes` or lies under one; no prefixes at all is the whole tree.
    private static func isUnder(_ path: String, prefixes: [String]) -> Bool {
        prefixes.isEmpty || prefixes.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
    }
}

extension DupesSearch {
    /// Two indices into the compared declarations, lower first, so a pair proposed by two callees is one pair.
    struct IndexPair: Hashable {
        let low: Int
        let high: Int
    }

    /// A pair that cleared the floor, with the hit that scored it.
    struct ScoredPair {
        let low: Int
        let high: Int
        let hit: SimilarHit
    }
}
