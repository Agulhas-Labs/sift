//
// Copyright © Agulhas Labs
//

import Foundation

/// The index call a cold search was reaching for — the *shape* of the miss, without the text that made it.
///
/// The cold count answers "how often did a session go around the index" and stops there, which is half a finding. Hundreds of misses over a week is a number to worry about; it is not a number to act on. What makes it actionable is knowing that one transcript's sixty greps were sixty `where` questions — one habit, closed by one rule — rather than sixty separate things the index could not have answered anyway. The audit has this in hand at the moment it classifies each miss: the same advisors the PreToolUse hook uses can name the call, because naming it is exactly what the hook does.
///
/// Deliberately a **verb and nothing else**. The suggestion this is read off carries the symbol too (`digest SummaryState.refresh()`), and that symbol is the caller's code — recording it would write the thing redaction exists to remove into the one part of the report that most wants to travel. A verb is a category: identical on every machine, meaningless to no one, and unchanged by redaction. The actionable half of this report is therefore also the half that is always safe to share.
public enum MissedCall: String, Sendable, Equatable, Codable, CaseIterable {
    /// A symbol was named and not confined to one file — `where` resolves it to declaration, callers, conformers and overrides.
    case resolve = "where"

    /// A query about shape rather than text — `search kind: attr: calls:`, which no text match can express.
    case shape = "search"

    /// A file, or one member of one — `digest`, which names every member with its exact line range.
    case digest

    /// What each verb buys, read off the same suggestion the hook would have made.
    ///
    /// Not written out here: a second wording of every call would sit one property below a comment explaining that re-deriving the mapping is what lets the audit and the hook drift apart. The arguments below are stand-ins chosen only to select the variant: what is wanted is the sentence, which is the caller's either way.
    public var yields: String {
        switch self {
        case .resolve: IndexSuggestion.forLookup(symbol: "Symbol", file: nil).yields
        case .shape: IndexSuggestion.forLookup(symbol: nil, file: nil).yields
        case .digest: IndexSuggestion.forLookup(symbol: nil, file: "File.swift").yields
        }
    }

    /// The call a suggestion stands for, or `nil` when it is not a lookup suggestion at all.
    ///
    /// Read off the suggestion's first word rather than re-deriving the mapping, so the audit and the hook cannot drift: `IndexSuggestion.forLookup` documents itself as the single place that rule lives, and a second copy of it here would be a second thing to keep true. A toolchain-run suggestion begins `sift run`, matches no verb, and correctly yields `nil`.
    public init?(_ suggestion: IndexSuggestion) {
        guard let verb = suggestion.call.split(separator: " ").first else { return nil }
        self.init(rawValue: String(verb))
    }
}
