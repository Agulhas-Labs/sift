//
// Copyright © Agulhas Labs
//

import Foundation

/// The block of name-matched sites a `where` answer falls back to where the store cannot answer, as it is written and as it is read back.
///
/// Its sites are leads, not locations: a name is not a symbol, so they take in same-named members of unrelated types and same-named locals and parameters. A reader of a finished answer — the transcript scan — has to tell them apart from what the answer resolved, and the line that opens the block — its heading, or a name's count line saying `by written name` — is how. Kept here, beside the wording, so the writer and the reader cannot drift.
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

    /// The lines of a finished answer that sit outside its name-matched block, which are everything it resolved (``partition(answer:)``).
    public static func linesOutside(answer: String) -> [Substring] {
        partition(answer: answer).outside
    }

    /// Every line of a file the block shows by its path and number: each row under a file's path, and each line a row of a type's uses lists — never one only counted (`+3 more`).
    ///
    /// Such a line accounts for the grep line it shows, since the reader sees that very line, but it locates nothing: ``ExactAnswer/locations(inWhereAnswer:)`` never reads the block, so the audit credits no file only these name.
    public static func shownLines(inAnswer answer: String) -> Set<ExactAnswer.Location> {
        var shown = Set<ExactAnswer.Location>()
        var heading: (indent: Int, path: String)?
        for line in partition(answer: answer).inside {
            if let match = line.wholeMatch(of: siteRow), let heading, match.output.1.count == heading.indent + 2, let number = Int(match.output.2) {
                shown.insert(ExactAnswer.Location(path: heading.path, line: number))
            } else if let match = line.wholeMatch(of: ExactAnswer.referenceLine) {
                heading = nil
                for number in match.output.2.split(separator: ",") {
                    if let value = Int(number.trimmingCharacters(in: .whitespaces)) {
                        shown.insert(ExactAnswer.Location(path: String(match.output.1), line: value))
                    }
                }
            } else {
                heading = line.wholeMatch(of: fileHeading).map { ($0.output.1.count, String($0.output.2)) }
            }
        }
        return shown
    }
}

private extension NameMatchedSites {
    struct SiteRow: Hashable {
        let line: Int
        let detail: String
    }

    /// A file's path as ``rows(_:detail:)`` heads its sites, `  path.swift:`, or with a count before the colon — or two spaces deeper, as a sub-heading's own sites are listed under it (those reaching another initializer by their labels).
    nonisolated(unsafe) static let fileHeading = #/( {2}| {4})(\S.*\.swift)(?: \(\d+\))?:/#

    /// A site row two spaces deeper than its ``fileHeading``, `    :12  detail  | text`, a line several sites share counted after it, `    :12 (×2)  …`.
    nonisolated(unsafe) static let siteRow = #/( {4}| {6}):(\d+)(?: \(×\d+\))?(?:  .*)?/#

    /// A name's count line that opens the block with no heading above it, `"save" (19 call sites by written name in 13 files):`, or `uses` for a type.
    nonisolated(unsafe) static let countLineOpening = #/"[^"]*" \(\d+ (?:call sites?|uses?) by written name/#

    /// How a name's verdict that it lists no site opens, `no call spelled "save" anywhere in the working tree`: with no heading above it, it opens the block as a count line does, since the sites it counts without listing may be indented under it.
    static var absentVerdictOpenings: [String] {
        ["no call spelled \"", "no use spelled \"", "every call spelled \"", "every use spelled \"", "nothing spelled \""]
    }

    /// A finished answer's lines split at its name-matched block: those inside it, and every other.
    ///
    /// The block opens at its heading, or where no heading is written at a name's count line saying `by written name` or at its verdict that it lists no site (``absentVerdictOpenings``); either way it runs through the lines it writes — blank lines, a name's own count line in quotes, indented sites and truncation counts, a line saying no site was found — and ends at the first line of any other shape, which is where the answer's next section opens: every section heading `where` writes starts at the margin with a word.
    static func partition(answer: String) -> (inside: [Substring], outside: [Substring]) {
        var (inside, outside): ([Substring], [Substring]) = ([], [])
        var inBlock = false
        for line in answer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if headingOpenings.contains(where: { line.hasPrefix($0) }) {
                inBlock = true
                continue
            }
            let opens = line.prefixMatch(of: countLineOpening) != nil || absentVerdictOpenings.contains { line.hasPrefix($0) }
            if opens {
                inBlock = true
            }
            if inBlock, opens || line.isEmpty || line.hasPrefix("\"") || line.first?.isWhitespace == true || line.hasPrefix("no ") {
                inside.append(line)
                continue
            }
            inBlock = false
            outside.append(line)
        }
        return (inside, outside)
    }
}
