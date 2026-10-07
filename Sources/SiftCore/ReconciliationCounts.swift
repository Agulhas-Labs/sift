//
// Copyright © Agulhas Labs
//

import Foundation

/// The one line of arithmetic a reconciled run is read on, whichever runner produced it.
///
/// A sharded `xcodebuild` run and an ordinary `swift test` answer the same question — did what was supposed to run, run — so they answer it in the same seven words rather than in two vocabularies a reader has to learn separately.
public struct ReconciliationCounts: Sendable, Equatable {
    /// How many tests were expected to report an ending: what a plan said would run, or what the index declares inside the run's own container.
    public let expected: Int

    /// How many of them the run reported an ending for, retries counted once.
    public let ran: Int

    public let passed: Int
    public let failed: Int
    public let skipped: Int

    /// How many tests were expected and never reported on, the unnameable shortfall of a count-only group included.
    public let missing: Int

    /// How many tests ended more than once — twice within one iteration, or, where the run was sharded, in two shards.
    public let duplicated: Int

    /// How many tests were expected and reported no ending of their own, whose result lines a passing suite and passing run summaries account for.
    public let linesLost: Int

    public init(expected: Int, ran: Int, passed: Int, failed: Int, skipped: Int, missing: Int, duplicated: Int, linesLost: Int = 0) {
        self.expected = expected
        self.ran = ran
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.missing = missing
        self.duplicated = duplicated
        self.linesLost = linesLost
    }

    /// The counts line the answer prints, which is the whole of this type in the order the design names them.
    public var line: String {
        "expected \(expected) · ran \(ran) · passed \(passed) · failed \(failed) · skipped \(skipped) · missing \(missing) · duplicated \(duplicated)\(linesLost > 0 ? " · lines lost \(linesLost)" : "")"
    }
}
