//
// Copyright © Agulhas Labs
//

import Foundation

/// A `root:` term written inside a search query, lifted back out to the argument it was meant to be.
///
/// The shape it catches: `search uses:colorScheme root:/Users/…/Depot/app`. The query language teaches `field:value` and the tool takes `root` as a separate argument, so a model folding the one into the other is a reasonable mistake — and "unknown field root" would refuse a call whose intent was unambiguous. The term is removed wherever it appears in the query; an explicit `root` argument still wins, because an argument is deliberate where an inline term may be habit. The `PreToolUse` hook treats the term as an explicit root too, and so adds none of its own.
struct InlineRootLift {
    /// The query with any `root:` terms removed; untouched when there were none.
    let query: String
    /// The last non-empty inline `root:` value, or `nil`.
    let root: String?

    init(query: String) {
        var root: String?
        var lifted = false
        let kept = query.split(whereSeparator: \.isWhitespace).filter { piece in
            guard piece.hasPrefix("root:") else { return true }
            lifted = true
            let value = piece.dropFirst("root:".count)
            if !value.isEmpty {
                root = String(value)
            }
            return false
        }
        self.query = lifted ? kept.joined(separator: " ") : query
        self.root = root
    }
}
