//
// Copyright © Agulhas Labs
//

/// Case-folded matching of `strings` queries against Swift string literals: people type on-screen text in the case they remember, not the case in source, so a query matches whatever its case.
struct CaseFoldedQuery {
    /// Whether `haystack` holds `query`, ignoring case.
    static func contains(_ haystack: String, query: String) -> Bool {
        haystack.localizedCaseInsensitiveContains(query)
    }

    /// The first range of `query` in `haystack`, ignoring case.
    static func range(of query: String, in haystack: String) -> Range<String.Index>? {
        haystack.range(of: query, options: .caseInsensitive)
    }
}
