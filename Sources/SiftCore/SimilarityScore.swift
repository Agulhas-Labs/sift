//
// Copyright © Agulhas Labs
//

/// How alike two declarations' shapes are — and the one place every constant that decides a `similar` answer lives.
///
/// Three terms, deliberately unequal. **Rarity-weighted callee overlap decides the answer**, because a helper is recognisable by the call it cannot do without: the three atomic file writes this tool was built to find share `rename`, `getpid` and `strerror`, and share almost nothing else with each other that they do not also share with half the repository. **The control-flow skeleton and the written type names are small corrections**, not votes of their own: an empty body and another empty body have identical skeletons, and a repository full of `func f(url: URL) throws` would rank on the word `URL` if types counted for much. Keeping the two small is what stops a hit that shares no interesting call from clearing the floor on shape alone.
///
/// The weights are picked, not derived, and they are meant to be read as a claim about the question rather than a tuning result: overlap at three quarters means no pair reaches the floor without real callee evidence behind it.
struct SimilarityScore {
    /// Rarity-weighted callee overlap — the term that has to carry a hit.
    static let calleeWeight = 0.75
    /// Control-flow skeleton similarity.
    static let skeletonWeight = 0.15
    /// Written parameter and return type overlap.
    static let typeWeight = 0.10

    /// The rarity-weighted callee overlap a candidate reaches to be listed at all — the one gate, and the reason "overlap dominates" is a property of this answer rather than a hope about its weights.
    ///
    /// Gating on the callee term alone, rather than on the composite score, is the whole of what keeps the list short. Two one-expression bodies have identical control-flow skeletons and often the same one written type, so the two small terms hand every pair of one-liners in the repository a quarter of a point for nothing: floored on the total, this repo answered a one-line `split`-and-`map` with 69 hits and put them above the three atomic file writes the tool was built to find. Floored on the overlap, the small terms order what is already through and can put nothing on the list.
    static let calleeFloor = 0.35

    /// The shared-callee overlap a pair reaches to be listed by `dupes`, well above `calleeFloor` because an audit of a whole tree has no target to anchor it.
    ///
    /// Picked from this repository's own tree: the one surviving pair of hand-rolled atomic JSON writes (`SetAsideStore.writeDurably(_:to:)` and `TestDurationStore.write()`, sharing `rename`, `replace`, `encode` and the encoder they build) sits at 0.51, so 0.50 is the highest floor that still lists it. Overlap alone cannot keep the list short at any floor that does — 646 pairs of `Sources/` cleared 0.50, most of them one-line helpers whose two or three calls happen to coincide — which is what `dupesEvidenceFloor` is for.
    static let dupesFloor = 0.5

    /// How much shared evidence a `dupes` pair needs besides its overlap, counted in callees only one declaration names: two such names shared, or several commoner ones adding up to as much.
    ///
    /// The overlap is a fraction, so two one-line bodies that make the same two calls reach 1.00 on nothing; this gate is on the summed rarity weight of what they share, the absolute amount the fraction hides. Counted in units of `CalleeRarity.singleWeight` rather than as a raw sum, because a weight is a logarithm of the scan's size and a raw threshold would mean something different under every path. Picked from the same tree as the floor: at 0.50 overlap, 2.5 units cut `Sources/` from 646 pairs to 82 — near-duplicate `day(of:timeZone:)`, `withCStrings(_:_:)`, `tail(of:bytes:)` and task-group scans in several types — and keep the atomic write pair, at 3.1.
    static let dupesEvidenceFloor = 2.5

    /// The most declarations one callee can be named by and still propose a `dupes` pair on its own.
    ///
    /// Candidate pairs come from an inverted index of callee to declarations, so this is what keeps the audit near-linear: a name forty bodies call (`append`, `map`, `joined`) would propose hundreds of pairs each and, weighted as common, could admit none of them. A pair that shares such a name is still scored on it once a rarer shared callee has proposed the pair; a pair that shares nothing rarer is never compared, which is one of the ways the audit is a lower bound.
    static let dupesFanOutBound = 40

    /// How much shared evidence the `PostToolUse` reuse nudge needs besides `similar`'s overlap floor, in the units of `dupesEvidenceFloor`: one callee only one declaration names, or several commoner ones adding up to as much.
    ///
    /// Picked from this repository's `Sources/SiftCore` scanned as the hook scans it (1431 nudges): the line that fired on `ImplementedRequirement.hedge(_:relation:)` toward `StructuralQuery.echo` (0.56 overlap, sharing only collection calls such as `joined` and `map`) weighs 0.92, below it, while near-twins such as `IfConfigLabel.label(for:source:)` and `label(line:in:)` weigh 1.35 and the two hand-rolled `withCStrings(_:_:)` 2.85.
    static let nudgeEvidenceFloor = 1.0

    /// The same gate for an added test function, higher because every test in a suite shares its lookup and `#expect` calls with every helper beside it.
    ///
    /// Picked from `Tests/SiftCoreTests` scanned the same way: the nudge toward `WhereFixedTextBudgetTests.assertBudget(_:root:sourceLocation:)` that fired at 0.40 and 0.47 overlap weighs 1.76 whichever test it is for, and a test that really copies a helper's body shares the helper's rarer calls on top, as the added test in `PostToolUseCommandTests` does.
    static let nudgeTestEvidenceFloor = 2.5

    /// Hits listed before the remainder is counted instead.
    ///
    /// Ten, because this answer is read to decide whether to write a helper, and the eleventh-closest shape has never decided that.
    static let resultCap = 10

    /// Shared callees named on a hit's evidence line, rarest first.
    static let sharedCalleeCap = 6

    /// The fewest calls a target's body can make and still be worth ranking.
    ///
    /// A body with one call has one piece of evidence, and one shared common name is enough to put anything on top of a list of two. Answering "too thin to compare" and naming the `search` recipe instead is the honest reading, and it is the same refuse-over-guess rule the freshness contract runs on (Docs/Design.md §2).
    static let minimumCallees = 3

    /// Control-flow tokens kept from one body, before the longest-common-subsequence comparison below turns quadratic on them.
    static let skeletonCap = 64

    /// `candidate` scored against `subject`, with the shared callees that earned it.
    static func hit(for candidate: DeclarationFingerprint, against subject: DeclarationFingerprint, rarity: CalleeRarity) -> SimilarHit {
        let shared = subject.callees.intersection(candidate.callees)
        var sharedWeight = 0.0
        var unionWeight = 0.0
        // Sorted, not the set's own order: a `Set<String>`'s iteration order is per-process hash order, and
        // summing floats in a different order sums them to a different rounding — which would make the same
        // pair of hits score a hair apart from one run to the next, and the exact `==` tie-break below no
        // longer a tie on the second run.
        for callee in subject.callees.union(candidate.callees).sorted() {
            let weight = rarity.weight(of: callee)
            unionWeight += weight
            if shared.contains(callee) {
                sharedWeight += weight
            }
        }
        // Weighted Jaccard, not the shared fraction of the subject's own weight: the asymmetric form scores a 300-line function that calls everything as a perfect match for every small one, which is the single most misleading hit this tool could return.
        let overlap = unionWeight > 0 ? sharedWeight / unionWeight : 0
        let score = calleeWeight * overlap
            + skeletonWeight * skeletonSimilarity(subject.skeleton, candidate.skeleton)
            + typeWeight * jaccard(subject.typeNames, candidate.typeNames)
        return SimilarHit(
            fingerprint: candidate,
            score: score,
            calleeOverlap: overlap,
            sharedCallees: rarestFirst(shared, rarity: rarity),
            sharedEvidence: rarity.singleWeight > 0 ? sharedWeight / rarity.singleWeight : 0
        )
    }

    /// The shared callees worth naming: rarest first, then alphabetically so the line is the same on every run, capped.
    static func rarestFirst(_ callees: Set<String>, rarity: CalleeRarity) -> [String] {
        let ordered = callees.sorted { left, right in
            let (leftWeight, rightWeight) = (rarity.weight(of: left), rarity.weight(of: right))
            return leftWeight == rightWeight ? left < right : leftWeight > rightWeight
        }
        return Array(ordered.prefix(sharedCalleeCap))
    }

    /// How alike two control-flow sequences are: twice the longest common subsequence over their combined length, which is 1 for identical sequences and 0 for two that share no token.
    ///
    /// A subsequence rather than a set, because order is the shape: guard-then-throw twice is not the same body as one `guard` and one `throw` written the other way round. Two bodies with no control flow at all have identical skeletons and score 1 — true, and harmless at this weight.
    static func skeletonSimilarity(_ subject: [DeclarationFingerprint.ControlToken], _ candidate: [DeclarationFingerprint.ControlToken]) -> Double {
        if subject.isEmpty, candidate.isEmpty {
            return 1
        }
        guard !subject.isEmpty, !candidate.isEmpty else { return 0 }
        let common = commonSubsequenceLength(subject, candidate)
        return 2 * Double(common) / Double(subject.count + candidate.count)
    }

    /// Plain set overlap — the small terms are not rarity-weighted, since a type name's frequency says much less about a body than a call's does.
    static func jaccard(_ subject: Set<String>, _ candidate: Set<String>) -> Double {
        let union = subject.union(candidate)
        guard !union.isEmpty else { return 0 }
        return Double(subject.intersection(candidate).count) / Double(union.count)
    }

    /// Longest common subsequence length, over one rolling row rather than a full table.
    private static func commonSubsequenceLength(_ subject: [DeclarationFingerprint.ControlToken], _ candidate: [DeclarationFingerprint.ControlToken]) -> Int {
        var previous = [Int](repeating: 0, count: candidate.count + 1)
        var current = previous
        for outer in subject.indices {
            for inner in candidate.indices {
                current[inner + 1] = subject[outer] == candidate[inner]
                    ? previous[inner] + 1
                    : max(previous[inner + 1], current[inner])
            }
            previous = current
        }
        return previous[candidate.count]
    }
}
