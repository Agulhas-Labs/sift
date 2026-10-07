//
// Copyright © Agulhas Labs
//

import Foundation

/// What one suite, or one shard's suites together, are predicted to hold a `swift test` process for, in wall seconds.
struct PackageShardLoad {
    /// The suites charged, in the order they were added.
    var suites: [String]
    /// Time that runs before or after everything else in the process: the summed durations of suites with no span.
    var serialSeconds: Double
    /// The longest span among the suites, which the process cannot finish before.
    var longestSpan: Double
    /// The spanned suites' shares of the wall clock, added up.
    var sharedSeconds: Double

    /// The wall clock predicted, before the process's own launch.
    var seconds: Double {
        serialSeconds + max(longestSpan, sharedSeconds)
    }

    /// Takes `other`'s suites into this load.
    mutating func add(_ other: Self) {
        suites += other.suites
        serialSeconds += other.serialSeconds
        longestSpan = max(longestSpan, other.longestSpan)
        sharedSeconds += other.sharedSeconds
    }
}
