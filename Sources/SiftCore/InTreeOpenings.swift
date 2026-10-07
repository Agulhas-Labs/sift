//
// Copyright © Agulhas Labs
//

/// What one query's opens of the in-tree stores came to: the stores that opened, in path order, and a clause for each that is still loading or failed.
struct InTreeOpenings {
    /// The stores open for this query, in path order.
    var opened: [SemanticStore] = []
    /// A clause for each store still loading or failed to open, for the `where` mode line.
    var pending: [String] = []
    /// The warming note for the first store still loading, which answers for them all when no store opened.
    var warmingNote: String?
}
