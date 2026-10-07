//
// Copyright © Agulhas Labs
//

import Foundation

/// How a sharded run's answer spells a duration.
///
/// One spelling for the plan's predictions and the merge's measurements both, because the answer prints them on the same line — `wall 41s (predicted 27s)` — and two roundings there would read as a disagreement rather than as the gap the line exists to show.
struct ShardSeconds {
    /// `21s` for a whole number of seconds, `0.2s` otherwise, rounded to a tenth.
    ///
    /// A tenth is what the frameworks themselves print for a test (`passed (0.001 seconds)` rounds to `0s`, which is the honest reading of a test that cost nothing worth planning around), and it keeps a shard line short enough to scan down a column of them.
    static func text(_ seconds: Double) -> String {
        let rounded = (seconds * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))s" : "\(rounded)s"
    }
}
