//
// Copyright © Agulhas Labs
//

/// Renders structural search results: grouped one block per file, budgeted, with what a `calls:` or `uses:` match is and isn't said in the answers that use those terms (Docs/Design.md §2, *standing caveats*).
struct SearchRenderer {
    /// Matches listed before the remainder is counted instead — the same budgeting discipline the digest applies, for the same reason.
    static var matchCap: Int {
        120
    }

    /// Renders `result` for `query`, paged from `offset`.
    static func render(result: StructuralSearch.Result, query: StructuralQuery, offset: Int = 0, typeBodyNote: String? = nil) -> String {
        var lines = query.echo.map { [$0] } ?? []
        guard !result.matches.isEmpty else {
            lines.append(missLine(result: result, query: query))
            lines.append(contentsOf: typeBodyNote.map { [$0] } ?? [])
            return withClause(lines, query: query)
        }

        lines.append(summaryLine(result: result))
        lines.append("")

        let start = min(max(0, offset), result.matches.count)
        let page = Array(result.matches.dropFirst(start).prefix(matchCap))
        if PastEndLine.applies(offset: offset, count: result.matches.count) {
            lines.append(PastEndLine.text(offset: offset, count: result.matches.count, noun: "matches"))
        } else if start > 0 {
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
            lines.append("  :\(match.line)-\(match.endLine)  \(match.qualifiedName) — \(SourceSlicer.shown(match.signature))")
        }
        let remaining = result.matches.count - start - page.count
        if remaining > 0 {
            lines.append("")
            let next = start + page.count
            if let names = remainderNames(result.matches.dropFirst(next), next: next) {
                lines.append(contentsOf: names)
            } else {
                lines.append("… truncated: \(remaining) more matches — pass offset \(next)")
            }
        }
        return withClause(lines, query: query)
    }

    /// `lines` joined, ending in the clause on what `calls:` and `uses:` match when the query has such a term, empty answer or not, and on no other search answer.
    private static func withClause(_ lines: [String], query: StructuralQuery) -> String {
        let matchesWrittenNames = query.terms.contains { $0.field == .calls || $0.field == .uses }
        return (matchesWrittenNames ? lines + [StandingCaveats.searchClause] : lines).joined(separator: "\n")
    }

    /// The bytes the remainder's names may take before the truncation line stands in for them: about 135 names in 130 files.
    static var remainderBudget: Int {
        8000
    }

    /// The matches past the page as one line per file in first-appearance order, `path: Name, Name`, under a header, an extension named with its line range (`Name (:337-916)`) so `digest path:337-916` serves it; nil where they would not fit `remainderBudget`.
    private static func remainderNames(_ rest: ArraySlice<StructuralMatch>, next: Int) -> [String]? {
        var groups: [(path: String, names: [String])] = []
        var slot: [String: Int] = [:]
        for match in rest {
            let entry = match.kind == "extension" ? "\(match.qualifiedName) (:\(match.line)-\(match.endLine))" : match.qualifiedName
            if let index = slot[match.path] {
                groups[index].names.append(entry)
            } else {
                slot[match.path] = groups.count
                groups.append((match.path, [entry]))
            }
        }
        let header = "\(rest.count) more, names only (digest or offset \(next) for their rows):"
        let body = groups.map { "\($0.path): " + $0.names.joined(separator: ", ") }
        let size = ([header] + body).reduce(0) { $0 + $1.utf8.count + 1 }
        return size <= remainderBudget ? [header] + body : nil
    }

    /// `search --count`: the header, the summary line and — when the matches span more than one module — the per-module breakdown a caller would otherwise build by hand with `grep | sort | uniq -c`, and no listing.
    ///
    /// The summary line is the one `render(result:query:offset:)` opens with, so a caller comparing a count against the full answer for the same query reads the same numbers in the same place; this just stops before the page that made them expensive.
    static func renderCount(result: StructuralSearch.Result, query: StructuralQuery, typeBodyNote: String? = nil, moduleFor: (String) -> String) -> String {
        var lines = query.echo.map { [$0] } ?? []
        guard !result.matches.isEmpty else {
            lines.append(missLine(result: result, query: query))
            lines.append(contentsOf: typeBodyNote.map { [$0] } ?? [])
            return withClause(lines, query: query)
        }

        lines.append(summaryLine(result: result))

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
        return withClause(lines, query: query)
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
}
