//
// Copyright © Agulhas Labs
//

import Foundation

/// One rendering of a byte count, so the two faces over the usage log cannot disagree about how large the same number is.
///
/// Three significant figures at most, and the unit switches at the thousand rather than the kibibyte: these numbers are read beside a percentage to answer "is this worth installing", not to reconcile against a disk usage tool, and 11.9 MB is the form that question is asked in.
///
/// **Three significant figures, not one.** Integer division from 1 kB to 10 kB would leave a single figure and truncate the rest, so 1,999 B would print as `1 kB` — a 50% understatement, in the band a single answer's size most often lands in, of a number whose whole job is to be weighed. One decimal there keeps the third figure the rest of the ladder already has; above 10 kB a whole kilobyte *is* three of them.
public struct ByteSize {
    /// `count` as bytes, kilobytes to one decimal below ten, whole kilobytes, or megabytes to one decimal.
    public static func short(_ count: Int) -> String {
        if count < 1000 {
            return "\(count) B"
        }
        if count < 10000 {
            return String(format: "%.1f kB", Double(count) / 1000)
        }
        if count < 1_000_000 {
            return "\(count / 1000) kB"
        }
        return String(format: "%.1f MB", Double(count) / 1_000_000)
    }
}
