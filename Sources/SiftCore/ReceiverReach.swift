//
// Copyright © Agulhas Labs
//

/// What a qualified query's narrowing by receiver makes of a site: dropped only where the receiver is provably another type of the tree.
enum ReceiverReach: Sendable, Equatable {
    /// Written on, or inside, a type that may reach the member asked about: kept.
    case reaches
    /// Written on, or inside, another type the tree declares: dropped.
    case another
    /// Written on, or inside, a type the tree does not declare, which may hand on the member: kept, and counted apart.
    case outsideTree
    /// Written on a receiver the scan cannot type, a variable or a chain: kept, and counted apart.
    case untyped

    /// Whether the site stays listed.
    var isKept: Bool {
        self != .another
    }

    /// The clauses a name's line counts the kept sites by, for those kept only because their receiver could not be shown to be another type, or `[]` where none was.
    ///
    /// The receivers written on the sites kept as outside the tree are named with their counts, the most common three, so a name as common as `record` is read by whom it was written on without listing every site.
    static func keptClauses(_ reaches: [(site: SyntacticCallSite, reach: ReceiverReach)]) -> [String] {
        let outside = reaches.filter { $0.reach == .outsideTree }
        guard !outside.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for entry in outside {
            if case let .type(name, _, _)? = entry.site.receiver {
                counts[name, default: 0] += 1
            }
        }
        let top = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(3)
        let named = top.isEmpty ? "" : " (" + top.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + (counts.count > top.count ? ", …" : "") + ")"
        return ["\(outside.count) on types outside the tree\(named)"]
    }
}
