//
// Copyright © Agulhas Labs
//

/// One file on one side of a range: its declarations, its lines, the exact text each declaration is compared by, and everything outside them.
///
/// Built from one parse whose tree is discarded before this value exists (Docs/Design.md §2), and itself discarded as soon as the file's two sides have been compared — the gatherer never holds a whole range's sources at once.
struct DiffFileSide: Sendable {
    let file: ParsedFile
    let lines: [String]
    let outside: OutsideDeclarations

    static func parse(source: String, path: String) -> DiffFileSide {
        let (file, outside) = FileParser.parse(source: source, repoRelativePath: path) { tree, converter in
            OutsideDeclarations.of(tree, converter: converter)
        }
        return DiffFileSide(file: file, lines: SourcePassthrough.lines(of: source), outside: outside)
    }

    /// The text declaration `index` is compared by: its own text as the walk recorded it, or — for a declaration the walk found inside some larger region (a function declared in top-level code) — its lines.
    func ownText(of index: Int) -> String {
        let symbol = file.symbols[index]
        let named = OutsideDeclarations.SymbolKey(line: symbol.line, column: symbol.column, name: symbol.name)
        let unnamed = OutsideDeclarations.SymbolKey(line: symbol.line, column: symbol.column, name: nil)
        return outside.ownText[named] ?? outside.ownText[unnamed] ?? body(of: symbol)
    }

    /// A type's or extension's header — from its first line to its opening brace's — or its whole range where the walk recorded no brace.
    func headerRange(of index: Int) -> DeclarationRange {
        let symbol = file.symbols[index]
        let end = outside.headerEnds[OutsideDeclarations.SymbolKey(line: symbol.line, column: symbol.column, name: nil)] ?? symbol.endLine
        return DeclarationRange(line: symbol.line, endLine: max(symbol.line, min(end, symbol.endLine)))
    }

    /// A declaration's whole lines, as a reader would want them shown.
    func body(of symbol: ParsedSymbol) -> String {
        guard symbol.line >= 1, symbol.endLine >= symbol.line, symbol.endLine <= lines.count else { return "" }
        return lines[(symbol.line - 1) ..< symbol.endLine].joined(separator: "\n")
    }
}
