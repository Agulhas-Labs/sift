//
// Copyright © Agulhas Labs
//

/// The byte fields of one usage-log line: what the answer cost, and — only where the tool actually read it — the source that answer stands in for.
///
/// One type for both faces of the line, written by ``UsageLog`` and read by ``UsageScan``, on the same reasoning that gives both logs one appender: two definitions of what `outBytes` and `srcBytes` mean is how a reader and a writer come to disagree about the same file.
///
/// **The two are not a pair, and the asymmetry is the whole point.** `served` is knowable for every tool with no counterfactual whatsoever — it is the length of what went out — so every answered call records it, and the calls that are lookups rather than digests are not invisible. `source` is a *measurement*: the declaration source a digest actually read in order to summarise it. The lookup tools have no such number, because what they stand in for is a `grep` nobody ran and nobody can size; a modelled denominator there — a file count times an average, say — would make the saving unfalsifiable, which is the one thing a savings figure must never be. So it is absent for them rather than invented, and the report says out loud that its total is a floor.
///
/// Two consequences for anyone reading the log: `srcBytes` never appears without `outBytes`, since a denominator with no numerator measures nothing; and a line carrying neither either failed or predates the field that would have carried it.
public struct AnswerBytes: Sendable, Equatable {
    /// The bytes the caller received — freshness header, alias note, adopted-root line and replacement notice included, since those are bytes it paid for.
    public let served: Int

    /// The source this answer stands in for, or `nil` where there is no honest denominator to record.
    public let source: Int?

    public init(served: Int, source: Int? = nil) {
        self.served = served
        self.source = source
    }
}
