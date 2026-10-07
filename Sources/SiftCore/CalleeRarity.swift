//
// Copyright © Agulhas Labs
//

import Foundation

/// What sharing a given callee is worth, measured over the tree that was actually scanned.
///
/// The term that makes `similar` usable rather than noisy. Every Swift body calls `append`, `map`, `init` and `count`, so an unweighted overlap ranks the two longest functions in the repository as each other's closest match and buries the pair that both call `rename`. Inverse document frequency prices each name by how many declarations call it: a common name counts for a fraction of what a rare one does (measured at n=6390 over this repository's own scan: `map` weighs 1.66, `append` 2.24, `rename` 6.68, a callee named by one other declaration 8.76 — a common name is roughly a fifth to a third of a rare one), and several common names shared can still outweigh one rare one, which is why a hit's evidence line names what actually earned it rather than just its count.
///
/// Measured over the scan, not over a table of known-common Swift names. A list would be wrong in every repository but the one it was written for — `save` is ubiquitous in a persistence layer and rare in a parser — and it would go stale the moment a codebase grew a habit.
struct CalleeRarity: Sendable {
    private let weights: [String: Double]

    /// The weight of a callee exactly one scanned declaration names — the most any one shared name can be worth in this scan.
    let singleWeight: Double

    /// Prices every callee named by any of `fingerprints`.
    init(fingerprints: [DeclarationFingerprint]) {
        var frequency: [String: Int] = [:]
        for fingerprint in fingerprints {
            for callee in fingerprint.callees {
                frequency[callee, default: 0] += 1
            }
        }
        // Smoothed by one declaration, which matters only at the small end and matters a lot there: unsmoothed, a callee named by *every* declaration weighs exactly zero, so in a tree of two functions every name they share is worth nothing and two identical bodies score as unrelated. Over a real repository log((n+1)/df) and log(n/df) are the same number to two decimals.
        let total = Double(fingerprints.count + 1)
        weights = frequency.mapValues { log(total / Double($0)) }
        singleWeight = log(total)
    }

    /// `callee`'s weight — zero for a name no scanned declaration calls, which is what a name that cannot be shared is worth.
    func weight(of callee: String) -> Double {
        weights[callee] ?? 0
    }
}
