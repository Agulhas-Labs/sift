//
// Copyright © Agulhas Labs
//

import Foundation

/// Traces display text to its localization key and a key to its text, across the repo's string catalogs — then to the Swift lines that spell the key as a literal, and to the Swift string literals that hold the wording itself.
///
/// Reads the working tree at query time, like structural search: catalogs are few and small, so there is nothing to index and therefore no staleness axis. The deliberate boundary (Docs/Design.md §3): matching is over **catalog keys and values, literal spellings of the key, and the text inside Swift string literals** — never comments, identifiers or other files, which is grep's job and stays grep's job. A key referenced only through a generated accessor (a `Strings` enum, an R-type) has no literal spelling; the answer names that gap instead of letting an empty site list read as "unused".
struct StringCatalogSearch {
    let repoRoot: URL
    let catalogPaths: () throws -> [String]
    let swiftPaths: () -> [String]
    /// Parses each catalog at most once per freshness window — see `StringCatalogCache`.
    let cache: StringCatalogCache

    /// Keys matched per query before the list truncates; literal scanning covers at most `literalKeyCap` keys.
    static var hitCap: Int {
        40
    }

    static var literalKeyCap: Int {
        5
    }

    static var literalSiteCap: Int {
        20
    }

    func run(query: String) throws -> Answer {
        let paths = try catalogPaths()
        var hits: [Hit] = []
        for path in paths.sorted() {
            let url = repoRoot.appendingPathComponent(path)
            if path.hasSuffix(".xcstrings") {
                hits.append(contentsOf: xcstringsHits(query: query, path: path, url: url))
            } else {
                hits.append(contentsOf: legacyStringsHits(query: query, path: path, url: url))
            }
        }
        // Exact key matches first, then catalog order — an agent asking by key wants that key, not its substring cousins.
        hits.sort { ($0.exactKeyMatch ? 0 : 1, $0.catalog, $0.key) < ($1.exactKeyMatch ? 0 : 1, $1.catalog, $1.key) }
        let scanKeys = hits.prefix(Self.literalKeyCap).map(\.key)
        let literalSites = literalOccurrences(of: Array(Set(scanKeys)))
        return Answer(
            hits: hits,
            catalogsSearched: paths.count,
            literalSites: literalSites,
            sourceLiterals: SourceLiteralSearch(repoRoot: repoRoot, swiftPaths: swiftPaths).run(query: query),
            accessorTrails: accessorTrails(scanKeys: scanKeys, literalSites: literalSites)
        )
    }

    /// The trail of each of the first few scanned keys no literal spells, followed to the accessor its last component names.
    private func accessorTrails(scanKeys: [String], literalSites: [String: [String]]) -> [String: StringsAccessorFollow.Trail] {
        var seen: Set<String> = []
        let followed = scanKeys
            .filter { literalSites[$0]?.isEmpty == true && seen.insert($0).inserted }
            .compactMap { key in StringsAccessorFollow.accessor(of: key).map { (key: key, accessor: $0) } }
            .prefix(StringsAccessorFollow.keyCap)
        guard !followed.isEmpty else { return [:] }
        let trails = StringsAccessorFollow(repoRoot: repoRoot, swiftPaths: swiftPaths).run(accessors: followed.map(\.accessor))
        return Dictionary(uniqueKeysWithValues: followed.compactMap { pair in trails[pair.accessor].map { (pair.key, $0) } })
    }

    // MARK: Catalog readers

    private func xcstringsHits(query: String, path: String, url: URL) -> [Hit] {
        guard case let .modern(sourceLanguage, strings)? = cache.content(at: url, isXcstrings: true) else {
            return []
        }
        var hits: [Hit] = []
        for (key, entry) in strings {
            let localizations = ((entry as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
            var valuesByLanguage: [String: [String]] = [:]
            for (language, localization) in localizations {
                var values: [String] = []
                collectValues(localization, into: &values)
                valuesByLanguage[language] = values
            }
            let exactKey = key == query
            let keyMatches = exactKey || key.contains(query)
            let valueMatches = valuesByLanguage.values.joined().contains { $0.range(of: query, options: .caseInsensitive) != nil }
            guard keyMatches || valueMatches else { continue }
            // A key with no localizations is its own display text — common for developer-facing catalogs.
            let display = valuesByLanguage[sourceLanguage]?.first ?? valuesByLanguage.values.first?.first
            hits.append(Hit(catalog: path, key: key, value: display, languageCount: localizations.count, exactKeyMatch: exactKey))
        }
        return hits
    }

    /// Any `"value"` string beneath a localization — covers plain `stringUnit`s and plural/device variations without modelling the whole schema.
    private func collectValues(_ node: Any, into values: inout [String]) {
        guard let dictionary = node as? [String: Any] else { return }
        for (key, child) in dictionary {
            if key == "value", let text = child as? String {
                values.append(text)
            } else {
                collectValues(child, into: &values)
            }
        }
    }

    private func legacyStringsHits(query: String, path: String, url: URL) -> [Hit] {
        guard case let .legacy(table)? = cache.content(at: url, isXcstrings: false) else {
            return []
        }
        return table.compactMap { key, value in
            let exactKey = key == query
            guard exactKey || key.contains(query) || value.range(of: query, options: .caseInsensitive) != nil else { return nil }
            return Hit(catalog: path, key: key, value: value, languageCount: 1, exactKeyMatch: exactKey)
        }
    }

    // MARK: Literal occurrences

    /// `path:line` for each place a key appears quoted in Swift source — the `String(localized:)` / `NSLocalizedString` spelling — or, for a key holding format specifiers, spelled as an interpolated literal whose text between interpolations is the key's text between specifiers.
    private func literalOccurrences(of keys: [String]) -> [String: [String]] {
        guard !keys.isEmpty else { return [:] }
        var sites: [String: [String]] = Dictionary(uniqueKeysWithValues: keys.map { ($0, []) })
        let needles = keys.map { (key: $0, quoted: "\"\($0)\"") }
        let formatted = keys.compactMap { key in
            FormatKeyPieces.pieces(of: key).flatMap { pieces in pieces.contains { !$0.isEmpty } ? (key: key, pieces: pieces) : nil }
        }
        for path in swiftPaths() {
            guard let data = FileManager.default.contents(atPath: repoRoot.appendingPathComponent(path).path),
                  let source = String(data: data, encoding: .utf8)
            else { continue }
            let interested = needles.filter { source.contains($0.quoted) }
            let interpolated = source.contains("\\(") ? formatted.filter { key in key.pieces.allSatisfy { $0.isEmpty || source.contains($0) } } : []
            guard !interested.isEmpty || !interpolated.isEmpty else { continue }
            var lexer = SwiftLiteralLexer()
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let site = "\(path):\(number + 1)"
                for needle in interested where line.contains(needle.quoted) {
                    sites[needle.key, default: []].append(site)
                }
                guard !interpolated.isEmpty else { continue }
                let literals = lexer.literals(on: line)
                for spelling in interpolated where literals.contains(where: { $0.printedSegments == spelling.pieces }) && sites[spelling.key]?.last != site {
                    sites[spelling.key, default: []].append(site)
                }
            }
        }
        return sites
    }
}

extension StringCatalogSearch {
    /// One matched catalog entry.
    struct Hit {
        let catalog: String
        let key: String
        let value: String?
        let languageCount: Int
        let exactKeyMatch: Bool
    }
}

extension StringCatalogSearch {
    /// The full answer: matched entries, literal occurrences for the first few matched keys, and the Swift string literals holding the query.
    struct Answer {
        let hits: [Hit]
        let catalogsSearched: Int
        /// Key → `path:line` sites; a key present with an empty list was scanned and found nowhere.
        let literalSites: [String: [String]]
        /// Every Swift source line whose string literal contains the query, sorted by path then line.
        let sourceLiterals: [SourceLiteralSearch.Site]
        /// Catalog key → its accessor's trail, for the first few keys no literal spells; a key absent here keeps the advice line.
        var accessorTrails: [String: StringsAccessorFollow.Trail] = [:]
    }
}
