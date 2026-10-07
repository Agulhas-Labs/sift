//
// Copyright © Agulhas Labs
//

import Foundation

/// The block of name-matched sites a `where` answer falls back to where the store cannot answer, as it is written and as it is read back.
///
/// Its sites are leads, not locations: a name is not a symbol, so they take in same-named members of unrelated types and same-named locals and parameters. A reader of a finished answer — the transcript scan — has to tell them apart from what the answer resolved, and the heading that opens the block is how. Kept here, beside the wording, so the writer and the reader cannot drift.
public struct NameMatchedSites {
    /// How the block's heading opens.
    static var headingOpening: String {
        "syntactic call sites — by written name"
    }

    /// How the block opens for a type, whose sites are every place its name is written rather than its calls.
    static var typeUseHeadingOpening: String {
        "syntactic uses — by written name"
    }

    /// Every way the heading has opened, the current ones first: an answer recorded in a transcript before the wording changed is still read back.
    static var headingOpenings: [String] {
        [headingOpening, typeUseHeadingOpening, "syntactic call sites — matched on written name"]
    }

    /// The characters of a site's source line the block prints before cutting it.
    static var sourceTextLimit: Int {
        140
    }

    /// Sites as the block lists them: each file's path once, indented under the name it matched, and one row per line under it, lines ascending, each with `detail`'s wording — a line repeated by more than one site with the same wording prints once with a `(×N)` count — so a call site cap keeps counting sites, not the rows they fold onto.
    ///
    /// Each row ends with the trimmed text of its source line, so the site can be judged without reading the file; a site whose line was not read prints its row without it. The path is indented rather than written at the margin, as `search` writes its file headings, because a margin line of that shape would end the block for ``linesOutside(answer:)`` and every site after it would be read back as a location the answer resolved.
    static func rows(_ sites: some Sequence<SyntacticCallSite>, detail: (SyntacticCallSite) -> String) -> [String] {
        var paths: [String] = []
        var byPath: [String: [SyntacticCallSite]] = [:]
        for site in sites {
            if byPath[site.path] == nil {
                paths.append(site.path)
            }
            byPath[site.path, default: []].append(site)
        }
        return paths.flatMap { path -> [String] in
            var order: [SiteRow] = []
            var sitesByRow: [SiteRow: [SyntacticCallSite]] = [:]
            for site in byPath[path] ?? [] {
                let row = SiteRow(line: site.line, detail: detail(site))
                if sitesByRow[row] == nil {
                    order.append(row)
                }
                sitesByRow[row, default: []].append(site)
            }
            let firstSeen = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let rows = order.sorted { ($0.line, firstSeen[$0] ?? 0) < ($1.line, firstSeen[$1] ?? 0) }.map { row -> String in
                let onLine = sitesByRow[row] ?? []
                let count = onLine.count > 1 ? " (×\(onLine.count))" : ""
                return "    :\(row.line)\(count)  \(row.detail)" + textSuffix(onLine.lazy.compactMap(\.text).first)
            }
            return ["  \(path):"] + rows
        }
    }

    /// What a row ends with for a site line whose text is `text`: the text after a bar, or nothing where the line was not read.
    static func textSuffix(_ text: String?) -> String {
        text.map { "  | \($0)" } ?? ""
    }

    /// A source line as a row prints it: trimmed, every run of whitespace one space, and cut at ``sourceTextLimit`` characters with a trailing ellipsis, or `nil` for a line with nothing on it.
    static func sourceText(_ line: some StringProtocol) -> String? {
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > sourceTextLimit else { return collapsed }
        return collapsed.prefix(sourceTextLimit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The lines of a finished answer that sit outside its name-matched block, which are everything it resolved.
    ///
    /// The block runs from its heading through the lines it writes — blank lines, a name's own heading in quotes, indented sites and truncation counts, a line saying no site was found — and ends at the first line of any other shape, which is where the answer's next section opens: every section heading `where` writes starts at the margin with a word.
    public static func linesOutside(answer: String) -> [Substring] {
        var outside: [Substring] = []
        var inBlock = false
        for line in answer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if headingOpenings.contains(where: { line.hasPrefix($0) }) {
                inBlock = true
                continue
            }
            if inBlock, line.isEmpty || line.hasPrefix("\"") || line.first?.isWhitespace == true || line.hasPrefix("no ") {
                continue
            }
            inBlock = false
            outside.append(line)
        }
        return outside
    }
}

private extension NameMatchedSites {
    struct SiteRow: Hashable {
        let line: Int
        let detail: String
    }
}
