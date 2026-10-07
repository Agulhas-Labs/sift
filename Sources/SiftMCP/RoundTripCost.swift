//
// Copyright © Agulhas Labs
//

import Foundation

/// What one round trip cost, split the way the harness bills it and priced the way Anthropic does: uncached input at full price, a cache read at a tenth of it, and a cache write at what creating the cache actually costs — 1.25× for a five-minute entry, 2× for a one-hour one.
///
/// `message.usage` carries `cache_creation: { ephemeral_5m_input_tokens, ephemeral_1h_input_tokens }` on a harness new enough to split it; where that field is absent, the flat `cache_creation_input_tokens` is the only figure a transcript ever wrote, and there is no way to tell a five-minute write from a one-hour one inside it — so the whole figure is read as five-minute, the cheaper of the two, rather than guess a split the transcript never recorded.
public struct RoundTripCost: Sendable, Equatable, Codable {
    public var uncachedInputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int

    public init(
        uncachedInputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    /// Every token the round trip re-sent, whatever kind — the raw total `message.usage` reports.
    public var rawTokens: Int {
        uncachedInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// The re-sent tokens priced as if every one of them had been uncached input — a price comparison against the uncached input rate, not a token count.
    ///
    /// Uncached ×1, a cache read ×0.1, a cache write ×1.25 for a five-minute entry and ×2 for a one-hour one, Anthropic's own multipliers relative to that rate. Rounded once, at the end, rather than per term.
    public var inputEquivalentTokens: Int {
        let equivalent = Double(uncachedInputTokens)
            + Double(cacheReadTokens) * 0.1
            + Double(cacheWrite5mTokens) * 1.25
            + Double(cacheWrite1hTokens) * 2.0
        return Int(equivalent.rounded())
    }

    public static func += (lhs: inout RoundTripCost, rhs: RoundTripCost) {
        lhs.uncachedInputTokens += rhs.uncachedInputTokens
        lhs.cacheReadTokens += rhs.cacheReadTokens
        lhs.cacheWrite5mTokens += rhs.cacheWrite5mTokens
        lhs.cacheWrite1hTokens += rhs.cacheWrite1hTokens
    }
}
