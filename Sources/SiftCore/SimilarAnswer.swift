//
// Copyright © Agulhas Labs
//

/// What a `similar` query produced, as a value the renderer turns into text.
///
/// Four outcomes rather than an optional list, because three of them are not degraded rankings — they are different answers. A target too thin to compare, one several declarations answer to, and one nothing answers to each need saying as themselves; collapsing any of them into "no hits" would let an agent read "there is nothing to reuse" off a query that never ran.
public struct SimilarAnswer: Sendable {
    /// The target as the caller wrote it.
    public let target: String
    public let census: Census
    public let outcome: Outcome

    public init(target: String, census: Census, outcome: Outcome) {
        self.target = target
        self.census = census
        self.outcome = outcome
    }
}

public extension SimilarAnswer {
    /// The denominators every outcome is read against: a count of zero means something different against 12 files than against 7,000, exactly as it does for `search`.
    struct Census: Sendable {
        public let filesScanned: Int
        /// Declarations with a body — the population that was actually ranked, which is a good deal smaller than the declaration count a digest reports.
        public let candidates: Int

        public init(filesScanned: Int, candidates: Int) {
            self.filesScanned = filesScanned
            self.candidates = candidates
        }
    }

    enum Outcome: Sendable {
        /// `hits` is capped at `SimilarityScore.resultCap`; `above` is how many cleared the floor in total.
        case ranked(subject: DeclarationFingerprint, hits: [SimilarHit], above: Int)
        /// The target resolved, but its body makes fewer than `SimilarityScore.minimumCallees` calls.
        case thin(subject: DeclarationFingerprint)
        /// Several declarations answer to the target — overloads, or a name two types both declare.
        case ambiguous([DeclarationFingerprint])
        /// Nothing with a body answers to the target.
        case unresolved
    }
}
