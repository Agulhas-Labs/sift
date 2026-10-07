//
// Copyright © Agulhas Labs
//

/// Where an untimed test's charge came from: its own target's median duration, or the plan's median over every timed test.
///
/// Carried beside the charge rather than inferred by comparing it to ``ShardPlan/estimatedSeconds``, because the two medians can coincide by chance — a target whose own timed tests happen to share the plan's median is still charged its own, and ``ShardPlan/estimateNote`` has to word that correctly rather than guess from the number alone.
public enum EstimateSource: Sendable, Equatable {
    case targetMedian
    case planMedian
}
