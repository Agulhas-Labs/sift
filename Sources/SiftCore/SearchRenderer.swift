//
// Copyright © Agulhas Labs
//

/// Renders structural search results: grouped one block per file, budgeted, and honest about what a shape match is and isn't.
struct SearchRenderer {
    /// Matches listed before the remainder is counted instead — the same budgeting discipline the digest applies, for the same reason.
    static var matchCap: Int {
        120
    }

    /// Renders `result` for `query`, paged from `offset`.
    static func render(result: StructuralSearch.Result, query: StructuralQuery, offset: Int = 0) -> String {
        var lines = [query.echo]
        guard !result.matches.isEmpty else {
            lines.append(missLine(result: result, query: query))
            lines.append(caveat(for: query))
            return lines.joined(separator: "\n")
        }

        lines.append(summaryLine(result: result))
        lines.append(caveat(for: query))
        lines.append("")

        let start = min(max(0, offset), result.matches.count)
        let page = Array(result.matches.dropFirst(start).prefix(matchCap))
        if start > 0 {
            lines.append("(…\(start) matches skipped)")
        }
        var currentPath = ""
        for match in page {
            if match.path != currentPath {
                if !currentPath.isEmpty {
                    lines.append("")
                }
                currentPath = match.path
                lines.append(currentPath + ":")
            }
            lines.append("  :\(match.line)-\(match.endLine)  \(match.qualifiedName) — \(match.signature)")
        }
        let remaining = result.matches.count - start - page.count
        if remaining > 0 {
            lines.append("")
            lines.append("… truncated: \(remaining) more matches — pass offset \(start + page.count)")
        }
        return lines.joined(separator: "\n")
    }

    /// `search --count`: the header, the summary line and — when the matches span more than one module — the per-module breakdown a caller would otherwise build by hand with `grep | sort | uniq -c`, and no listing.
    ///
    /// The summary line and the caveat are the same two lines `render(result:query:offset:)` opens with, so a caller comparing a count against the full answer for the same query reads the same numbers in the same place; this just stops before the page that made them expensive.
    static func renderCount(result: StructuralSearch.Result, query: StructuralQuery, moduleFor: (String) -> String) -> String {
        var lines = [query.echo]
        guard !result.matches.isEmpty else {
            lines.append(missLine(result: result, query: query))
            lines.append(caveat(for: query))
            return lines.joined(separator: "\n")
        }

        lines.append(summaryLine(result: result))
        lines.append(caveat(for: query))

        var byModule: [String: Int] = [:]
        for match in result.matches {
            byModule[moduleFor(match.path), default: 0] += 1
        }
        if byModule.count > 1 {
            lines.append("")
            for (module, matchCount) in byModule.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
                lines.append("  \(matchCount) \(module)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The count of matches and files over the files scanned, then — where a `name:` pattern matched some names whole and others only in part — how many lead the answer for matching whole.
    private static func summaryLine(result: StructuralSearch.Result) -> String {
        let fileCount = Set(result.matches.map(\.path)).count
        let summary = "\(result.matches.count) declaration(s) in \(fileCount) file(s) — scanned \(result.filesScanned) file(s)"
        guard splitsWholeFromPart(result) else { return summary }
        return summary + "; the \(result.wholeNameMatches) whose whole name matches come first"
    }

    /// Whether the answer has both groups, whole-name matches and partial ones; with only one there is no order to explain.
    private static func splitsWholeFromPart(_ result: StructuralSearch.Result) -> Bool {
        result.wholeNameMatches > 0 && result.wholeNameMatches < result.matches.count
    }

    /// The verdict on a miss: the denominator, then the term that removed the last declarations in the order the scan applied the terms, and how many it removed; bare where no declaration reached the terms.
    private static func missLine(result: StructuralSearch.Result, query: StructuralQuery) -> String {
        let bare = "no declarations match — scanned \(result.filesScanned) file(s)"
        let applied = query.appliedOrder
        guard let (position, removed) = result.eliminations.max(by: { $0.key < $1.key }), applied.indices.contains(position) else { return bare }
        let reach = removed == result.eliminations.values.reduce(0, +) ? "all" : "the last"
        return bare + "; \(applied[position].spelled) removed \(reach) \(removed) declaration(s)"
    }

    /// What the answer does and does not promise.
    ///
    /// Two limits, both load-bearing. The scan reads the working tree, so unlike the semantic axis it is never stale and never refuses — worth saying, because every other multi-file answer this tool gives carries a staleness caveat. But `calls:` and `uses:` match *written names*, not resolved symbols: two unrelated types with a `save` method are one name here. Stating that inline is the difference between a shape query used as a lead and one mistaken for a resolved fact.
    private static func caveat(for query: StructuralQuery) -> String {
        let base = "syntactic shape match over the working tree — never stale, never refuses"
        guard query.terms.contains(where: { $0.field == .calls || $0.field == .uses }) else {
            return base + "."
        }
        return base + "; calls:/uses: match written names, not resolved symbols, so same-named members of unrelated types are included — confirm a specific hit with where."
    }
}
