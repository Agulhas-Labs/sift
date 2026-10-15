//
// Copyright © Agulhas Labs
//

/// One row of a rendered block after folding: the row to print, and how many of the input rows it stands for — always 1 unfolded.
struct CallerFoldedRow {
    let entry: WhereRenderer.ListedRow
    let state: OccurrenceState
    let sites: Int

    /// Groups rows by calling function — name and declaring file — keeping the first call site (by line) of each and counting the rest, so a caller that calls the subject nine times prints once.
    ///
    /// Grouping is by identity, not adjacency: the store's own ordering is not relied on to keep one caller's sites together.
    static func folded(_ judged: [(entry: WhereRenderer.ListedRow, state: OccurrenceState)]) -> [CallerFoldedRow] {
        var order: [String] = []
        var groups: [String: [(entry: WhereRenderer.ListedRow, state: OccurrenceState)]] = [:]
        for row in judged {
            let key = "\(row.entry.hit.name)\u{0}\(row.entry.hit.path)"
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(row)
        }
        return order.map { key in
            let group = groups[key] ?? []
            let first = group.min { $0.entry.hit.line < $1.entry.hit.line } ?? group[0]
            // The first site's "referenced, not called" is the caller's only where none of its sites calls the subject.
            var entry = first.entry
            let uncalled = group.count { $0.entry.hit.uncalled }
            if uncalled > 0, uncalled < group.count {
                entry.access = "called and referenced"
            }
            return CallerFoldedRow(entry: entry, state: first.state, sites: group.count)
        }
    }
}
