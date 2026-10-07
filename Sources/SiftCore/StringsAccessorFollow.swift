//
// Copyright © Agulhas Labs
//

import Foundation

/// Follows a catalog key no Swift literal spells to the accessor its last component names: where that name is declared and where it is written, by written name over the working tree.
///
/// Closes the generated-accessor gap in the same strings answer instead of handing it back as advice. Each file spelling an accessor is parsed once, and that one tree is read twice: by the indexer's own declaration walk and by the name-matched sweep `where` runs. Nothing is resolved, so a same-named symbol elsewhere is listed with the accessor, and the answer says so.
struct StringsAccessorFollow {
    let repoRoot: URL
    let swiftPaths: () -> [String]

    /// Keys followed per answer; any further key keeps the advice line.
    static var keyCap: Int {
        3
    }

    /// Use sites listed per accessor before the rest are counted.
    static var siteCap: Int {
        12
    }

    /// Declarations listed per accessor before the rest are counted.
    static var declarationCap: Int {
        5
    }

    /// Characters of a site's source line shown before it ends in an ellipsis.
    static var textCap: Int {
        140
    }

    /// The accessor a key's last dot-separated component names, or `nil` where that component is no Swift identifier, as the key spelled in English is not.
    static func accessor(of key: String) -> String? {
        guard let last = key.split(separator: ".", omittingEmptySubsequences: false).last,
              let first = last.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              last.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return String(last)
    }

    /// Each accessor's trail, keyed by accessor name; one read of the tree covers every name.
    func run(accessors: [String]) -> [String: Trail] {
        let names = Array(Set(accessors)).sorted()
        guard !names.isEmpty else { return [:] }
        var trails = Dictionary(uniqueKeysWithValues: names.map { ($0, Trail(declarations: [], sites: [])) })
        for path in swiftPaths().sorted() {
            guard let data = FileManager.default.contents(atPath: repoRoot.appendingPathComponent(path).path),
                  let source = String(data: data, encoding: .utf8)
            else { continue }
            let spelled = names.filter { source.contains($0) }
            guard !spelled.isEmpty else { continue }
            let shapes = Dictionary(uniqueKeysWithValues: spelled.map { ($0, CallSiteScanner.SiteShape.use) })
            let (file, scanned) = FileParser.parse(source: source, repoRelativePath: path) { tree, converter in
                CallSiteScanner.sites(in: tree, converter: converter, path: path, names: shapes)
            }
            let lines = SourcePassthrough.lines(of: source)
            for name in spelled {
                trails[name]?.declarations += Self.declarations(named: name, in: file)
                trails[name]?.sites += (scanned.sites[name] ?? []).map { site in
                    Site(path: site.path, line: site.line, enclosing: site.enclosing, text: Self.shown(lines, at: site.line))
                }
            }
        }
        return trails
    }

    /// The declarations in `file` whose base name is `name`, each qualified by the declarations around it.
    private static func declarations(named name: String, in file: ParsedFile) -> [Declaration] {
        file.symbols.compactMap { symbol in
            guard CallSiteScanner.baseName(of: symbol.name) == name else { return nil }
            var qualified = [symbol.name]
            var parent = symbol.parentIndex
            while let current = parent {
                qualified.insert(file.symbols[current].name, at: 0)
                parent = file.symbols[current].parentIndex
            }
            return Declaration(kind: symbol.kind.rawValue, name: qualified.joined(separator: "."), path: file.path, line: symbol.line)
        }
    }

    /// Line `number` of `lines` with its whitespace collapsed, cut at `textCap` characters.
    private static func shown(_ lines: [String], at number: Int) -> String {
        guard lines.indices.contains(number - 1) else { return "" }
        let collapsed = lines[number - 1].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > textCap ? String(collapsed.prefix(textCap)) + "…" : collapsed
    }
}

extension StringsAccessorFollow {
    /// Where one accessor name is declared and where it is written.
    struct Trail {
        var declarations: [Declaration]
        var sites: [Site]
    }

    /// One declaration of the accessor name.
    struct Declaration {
        let kind: String
        let name: String
        let path: String
        let line: Int
    }

    /// One place the accessor name is written, with the line that writes it.
    struct Site {
        let path: String
        let line: Int
        let enclosing: String
        let text: String
    }
}
