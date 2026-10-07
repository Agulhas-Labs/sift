//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders a strings answer: matched entries grouped per catalog, then literal sites per key — honest about the generated-accessor gap — then the Swift string literals holding the wording.
struct StringsRenderer {
    /// Display cap for a value before it truncates with an ellipsis — the value identifies the entry, it is not the deliverable.
    static var valueDisplayCap: Int {
        80
    }

    static func render(answer: StringCatalogSearch.Answer, query: String) -> String {
        var lines = ["strings \"\(escapingControlCharacters(query))\""]
        if answer.catalogsSearched == 0 {
            lines.append("no string catalogs (.xcstrings / .strings) in this repo")
        } else if answer.hits.isEmpty {
            lines.append("no catalog entry matches — searched \(answer.catalogsSearched) catalog file\(answer.catalogsSearched == 1 ? "" : "s") (keys exactly or by substring, values case-insensitively)")
        } else {
            lines += catalogLines(answer: answer)
        }
        let plain = answer.sourceLiterals.filter { !$0.isAroundInterpolation }
        if !plain.isEmpty {
            lines.append("")
            lines += sourceLiteralLines(plain, heading: "source literals (Swift string literals holding the wording, not catalog entries):", query: query)
        }
        let around = answer.sourceLiterals.filter(\.isAroundInterpolation)
        if plain.isEmpty, answer.hits.isEmpty, !around.contains(where: \.isListable) {
            lines.append("no Swift string literal contains it either")
        }
        lines += StringsAroundSection.lines(around, query: query)
        return lines.joined(separator: "\n")
    }

    /// A source-literal section: one line per production site, `<declaration> — <path>:<line>: "<literal>"`, capped with a count of the rest, then test sites counted per file; a section matching only test sites lists them instead.
    ///
    /// A literal matched around its interpolations is windowed on where its written text spells the literal text it matched, since the query itself is not in its text, and shown from its start when that is nowhere; a run of literals a `+` joins is windowed on the range the search found, since `" + "` stands between the pieces of the query.
    static func sourceLiteralLines(_ sites: [SourceLiteralSearch.Site], heading: String, query: String) -> [String] {
        var lines = [heading]
        let production = sites.filter { !$0.isTest }
        let tests = sites.filter(\.isTest)
        let listed = production.isEmpty ? tests : production
        for site in listed.prefix(SourceLiteralSearch.siteCap) {
            let shown = site.around.map { around in around.window.map { windowed(site.literal, on: $0) } ?? truncated(site.literal) } ?? site.window.map { windowed(site.literal, on: $0) } ?? windowed(site.literal, around: query)
            let location = "\(site.path):\(site.line): \"\(shown)\""
            lines.append("  " + (site.declaration.map { "\($0) — \(location)" } ?? location))
        }
        if listed.count > SourceLiteralSearch.siteCap {
            lines.append("  +\(listed.count - SourceLiteralSearch.siteCap) more — narrow the query")
        }
        if !production.isEmpty, !tests.isEmpty {
            lines.append("  " + testSitesLine(tests))
        }
        return lines
    }

    /// Files named on the test-sites line before it ends in an ellipsis.
    private static var testFileCap: Int {
        5
    }

    /// `in tests: 23 sites in 9 files — RunCommandKindTests.swift (2), …`, files in path order.
    private static func testSitesLine(_ tests: [SourceLiteralSearch.Site]) -> String {
        var counts: [(path: String, count: Int)] = []
        for site in tests {
            if let last = counts.indices.last, counts[last].path == site.path {
                counts[last].count += 1
            } else {
                counts.append((site.path, 1))
            }
        }
        let shown = Array(counts.prefix(testFileCap))
        let names = shortestDistinctSuffixes(shown.map(\.path))
        let named = zip(names, shown).map { "\($0) (\($1.count))" }
        let more = counts.count > testFileCap ? ", …" : ""
        // The rule is said beside the number, as `where` does: a helper in a test directory importing no framework is production.
        return "in tests: \(tests.count) site\(tests.count == 1 ? "" : "s") in \(counts.count) file\(counts.count == 1 ? "" : "s") — " + named.joined(separator: ", ") + more + ", split on the XCTest or Testing import, never the path"
    }

    /// Each path's last component, extended by parent directories only as far as it takes to tell it from another path ending the same way.
    private static func shortestDistinctSuffixes(_ paths: [String]) -> [String] {
        let components = paths.map { $0.split(separator: "/").map(String.init) }
        return components.map { parts in
            var depth = 1
            while depth < parts.count {
                let suffix = parts.suffix(depth)
                if components.filter({ $0.suffix(depth).elementsEqual(suffix) }).count == 1 {
                    break
                }
                depth += 1
            }
            return parts.suffix(depth).joined(separator: "/")
        }
    }

    /// The catalog section: matched entries grouped per catalog, then each scanned key's literal sites.
    private static func catalogLines(answer: StringCatalogSearch.Answer) -> [String] {
        var lines: [String] = []
        let catalogs = Set(answer.hits.map(\.catalog)).count
        lines.append("\(answer.hits.count) key\(answer.hits.count == 1 ? "" : "s") in \(catalogs) catalog\(catalogs == 1 ? "" : "s") — searched \(answer.catalogsSearched) catalog file\(answer.catalogsSearched == 1 ? "" : "s"); working-tree read, never stale")
        lines.append("")

        var currentCatalog = ""
        for hit in answer.hits.prefix(StringCatalogSearch.hitCap) {
            if hit.catalog != currentCatalog {
                if !currentCatalog.isEmpty {
                    lines.append("")
                }
                currentCatalog = hit.catalog
                lines.append(currentCatalog + ":")
            }
            let value = hit.value.map { "\"\(escapedValue(truncated($0)))\"" } ?? "(no value — key is its own display text)"
            let languages = hit.languageCount > 1 ? "  (\(hit.languageCount) languages)" : ""
            lines.append("  \(escapingControlCharacters(hit.key)) = \(value)\(languages)")
        }
        if answer.hits.count > StringCatalogSearch.hitCap {
            lines.append("  truncated: \(answer.hits.count - StringCatalogSearch.hitCap) more keys — narrow the query")
        }

        if !answer.literalSites.isEmpty {
            lines.append("")
            lines.append("literal occurrences in Swift source (keys spelled as string literals — String(localized:)/NSLocalizedString style):")
            for key in answer.literalSites.keys.sorted() {
                let sites = answer.literalSites[key] ?? []
                if sites.isEmpty, let trail = answer.accessorTrails[key], let accessor = StringsAccessorFollow.accessor(of: key) {
                    lines += accessorLines(key: key, accessor: accessor, trail: trail)
                } else if sites.isEmpty {
                    lines.append("  \(quotedKey(key)): none — likely referenced through a generated accessor (a Strings enum, an R-type); use where/search on the generated symbol")
                } else {
                    let listed = sites.prefix(StringCatalogSearch.literalSiteCap).joined(separator: ", ")
                    let extra = sites.count > StringCatalogSearch.literalSiteCap ? ", +\(sites.count - StringCatalogSearch.literalSiteCap) more" : ""
                    lines.append("  \(quotedKey(key)): \(listed)\(extra)")
                }
            }
            if answer.hits.count > StringCatalogSearch.literalKeyCap {
                lines.append("  (literal scan covers the first \(StringCatalogSearch.literalKeyCap) matched keys)")
            }
        }
        return lines
    }

    /// A key no literal spells, followed to its accessor: the name's declarations, then the lines writing it, each with its enclosing declaration and its text.
    private static func accessorLines(key: String, accessor: String, trail: StringsAccessorFollow.Trail) -> [String] {
        let gap = "  \(quotedKey(key)): none — likely referenced through a generated accessor (a Strings enum, an R-type)"
        guard !trail.declarations.isEmpty || !trail.sites.isEmpty else {
            return [gap + "; no Swift file declares or writes \"\(accessor)\""]
        }
        var lines = [gap, "    accessor \"\(accessor)\" — matched by written name over the working tree, so a same-named symbol elsewhere may be listed:"]
        for declaration in trail.declarations.prefix(StringsAccessorFollow.declarationCap) {
            lines.append("      declared: \(declaration.kind) \(declaration.name) — \(declaration.path):\(declaration.line)")
        }
        if trail.declarations.count > StringsAccessorFollow.declarationCap {
            lines.append("      +\(trail.declarations.count - StringsAccessorFollow.declarationCap) more declarations — where \(accessor) lists them all")
        }
        if trail.sites.isEmpty {
            lines.append("      written nowhere outside its declaration")
        }
        for site in trail.sites.prefix(StringsAccessorFollow.siteCap) {
            lines.append("      \(site.path):\(site.line) in \(site.enclosing): \(site.text)")
        }
        if trail.sites.count > StringsAccessorFollow.siteCap {
            lines.append("      +\(trail.sites.count - StringsAccessorFollow.siteCap) more sites — where \(accessor) lists them all")
        }
        return lines
    }

    /// `text` with each control character written as an escape (`\n`, `\r`, `\t`, `\0`, else `\u{…}`), so a query or value holding one stays on its own line.
    static func escapingControlCharacters(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\0": escaped += "\\0"
            default:
                if scalar.properties.generalCategory == .control {
                    escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    /// A key between quotes, as a literal-occurrence or accessor line prints it: control characters and quotes escaped, so the key cannot split its line or end its quotes early.
    private static func quotedKey(_ key: String) -> String {
        "\"\(escapedValue(key))\""
    }

    /// A catalog value as written between quotes: control characters escaped, and each `"` as `\"`, so the closing quote is the one that ends the value.
    private static func escapedValue(_ value: String) -> String {
        escapingControlCharacters(value).replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func truncated(_ value: String) -> String {
        value.count <= valueDisplayCap ? value : String(value.prefix(valueDisplayCap)) + "…"
    }

    /// A literal's display window: the match plus a few characters of context each side, capped near `valueDisplayCap`, with `…` marking a trimmed end — so a match past the display cap stays visible instead of falling off the end.
    ///
    /// A match near the start renders with its leading text intact, matching a plain truncation; only a match further in gains a leading `…`.
    private static func windowed(_ value: String, around query: String) -> String {
        guard value.count > valueDisplayCap else {
            return value
        }
        guard let range = SmartCaseQuery.range(of: query, in: value) else {
            return truncated(value)
        }
        let matchStart = value.distance(from: value.startIndex, to: range.lowerBound)
        return windowed(value, on: matchStart ..< matchStart + value.distance(from: range.lowerBound, to: range.upperBound))
    }

    /// A display window on the characters at `match` of `value`, as ``windowed(_:around:)`` centres one on a query it finds.
    private static func windowed(_ value: String, on match: Range<Int>) -> String {
        guard value.count > valueDisplayCap else {
            return value
        }
        let matchStart = match.lowerBound
        let matchLength = match.count
        let context = max(0, (valueDisplayCap - matchLength) / 2)
        let startOffset = max(0, matchStart - context)
        let endOffset = min(value.count, matchStart + matchLength + context)
        let windowStart = value.index(value.startIndex, offsetBy: startOffset)
        let windowEnd = value.index(value.startIndex, offsetBy: endOffset)
        let leading = startOffset > 0 ? "…" : ""
        let trailing = endOffset < value.count ? "…" : ""
        return leading + value[windowStart ..< windowEnd] + trailing
    }
}
