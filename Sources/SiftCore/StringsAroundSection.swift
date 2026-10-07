//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders the strings answer's section for literals matched around their interpolations: the sites listed, then a count of the one-word matches it does not list, broken down by word.
struct StringsAroundSection {
    /// The section's lines for `sites`, every one matched around interpolations: a heading over the sites listed, or with none listed, the count alone on one line saying where it matched; empty when there are no sites.
    static func lines(_ sites: [SourceLiteralSearch.Site], query: String) -> [String] {
        let listed = sites.filter(\.isListable)
        let counted = sites.filter { !$0.isListable }
        // Matched on one query word only: counted so the answer accounts for them, never listed ahead of a real site.
        let count = "line\(counted.count == 1 ? " matches" : "s match") it"
        let tail = "on only one word of literal text, tests included, not listed — \(tally(counted, query: query)); add a word to narrow"
        guard !listed.isEmpty else {
            return counted.isEmpty ? [] : ["\(counted.count) \(count) around interpolations \(tail)"]
        }
        var lines = [""]
        lines += StringsRenderer.sourceLiteralLines(listed, heading: heading(listingOneWordMatches: listed.contains { $0.around?.word != nil }), query: query)
        if !counted.isEmpty {
            lines.append("  \(counted.count) more \(count) \(tail)")
        }
        return lines
    }

    /// The heading, which says so when the sites listed matched on one query word only: rare words, listed because nothing else lists.
    private static func heading(listingOneWordMatches: Bool) -> String {
        let how = listingOneWordMatches ? " on only one word of literal text, a word matched this way on at most \(SourceLiteralSearch.fallbackSiteLimit) production lines" : ""
        return "literals with interpolations, matched around them\(how) (each \\(…) read as some of the query's text, or none):"
    }

    /// `"more" 6, "lines" 30`: how many of `sites` matched on each query word, words in query order.
    private static func tally(_ sites: [SourceLiteralSearch.Site], query: String) -> String {
        var counts: [String: Int] = [:]
        for site in sites {
            if let word = site.around?.word {
                counts[word, default: 0] += 1
            }
        }
        let order = InterpolationWildcard.Query(query).wordTexts
        return counts.keys
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
            .map { "\"\($0)\" \(counts[$0, default: 0])" }
            .joined(separator: ", ")
    }
}
