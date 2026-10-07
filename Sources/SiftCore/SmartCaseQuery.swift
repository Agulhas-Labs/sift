//
// Copyright © Agulhas Labs
//

/// Ripgrep-style smart case: a query holding any uppercase letter matches case-sensitively, an all-lowercase query stays case-insensitive.
struct SmartCaseQuery {
    /// Whether `query` should match case-sensitively — any uppercase letter in it forces this.
    static func isCaseSensitive(_ query: String) -> Bool {
        query.contains { $0.isUppercase }
    }

    /// Whether `haystack` holds `query`, case-sensitively when `query` has an uppercase letter and case-insensitively otherwise.
    static func contains(_ haystack: String, query: String) -> Bool {
        isCaseSensitive(query) ? haystack.contains(query) : haystack.localizedCaseInsensitiveContains(query)
    }

    /// The first range of `query` in `haystack`, under the same smart-case rule as ``contains(_:query:)``.
    static func range(of query: String, in haystack: String) -> Range<String.Index>? {
        haystack.range(of: query, options: isCaseSensitive(query) ? [] : .caseInsensitive)
    }
}
