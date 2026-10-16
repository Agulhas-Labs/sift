//
// Copyright © Agulhas Labs
//

import Foundation

extension WhereRenderer {
    /// The declarations block of a `where` answer: its lines, the paths it cites, and the extension listings its rows were annotated from.
    struct DeclarationsBlock {
        let lines: [String]
        let cited: [String]
        let extensionListings: DeclaredExtensions.Listings
        let printedExtensions: Set<Int64>
    }

    /// The last line of a `--decl` answer: what it left out, and the query, as the caller wrote it, that covers it.
    static func declarationsOnlyPointer(query: String) -> String {
        "`where \(query)` without --decl covers its uses, extensions, conformers, callers and overrides."
    }

    /// The heading, the rows (an extension with its member count and mark), the cut line and the compact form's `signatures:` line.
    ///
    /// Under `declarationsOnly` a cut line that would name rows the extensions block lists points on to the answer that has the block instead, since `--offset` pages none of this.
    func declarationsBlock(_ declarations: [SymbolRow], query: String, written: String, declarationsOnly: Bool) throws -> DeclarationsBlock {
        var lines: [String] = []
        var cited: [String] = []
        let compact = declarations.count > Self.compactDeclarationThreshold
        lines.append("declarations (\(declarations.count)):")
        filesCollector?.recordDeclarationsHeading("declarations (\(declarations.count)):")
        // A type's own declaration leads its extensions, whatever its file sorts as: it is the row that says what the
        // name is, and a reader who takes the head of a long list of extensions would otherwise never see it.
        let listed = declarations.filter { $0.kind != .extensionKind } + declarations.filter { $0.kind == .extensionKind }
        // Every declaration, not the listed ones: the view names each file that declares the query, past the list's cap too.
        try filesCollector?.recordDeclarations(listed, qualifiedName: qualifiedName(of:))
        // An extension printed here is not printed again by the block under its type, and carries what that block would have said of it: its member count, and the mark on a row that may not be the type's.
        let extensionListings = try extensionListings(of: declarations)
        let printedExtensions = Set(listed.prefix(Self.listCap).filter { $0.kind == .extensionKind }.map(\.id))
        for row in listed.prefix(Self.listCap) {
            cited.append(row.path)
            let (memberCount, mark) = try DeclaredExtensions.annotation(of: row, listings: extensionListings, in: store)
            try lines.append(row.declarationLine(qualifiedName: qualifiedName(of: row), compact: compact, condition: IfConfigLabel.label(for: row, source: fileSource), memberCount: memberCount, mark: mark))
        }
        if declarations.count > Self.listCap {
            var tail = DeclaredExtensions.truncationTail(cut: listed.dropFirst(Self.listCap), listings: extensionListings, printed: printedExtensions, blockCap: Self.listCap)
            if declarationsOnly, !tail.isEmpty {
                tail = " — where \(written) lists " + tail.dropFirst(2)
            }
            lines.append("  truncated: \(declarations.count - Self.listCap) more declarations\(tail)")
        }
        if compact {
            lines.append("  signatures: digest \(query) for any one of these")
        }
        return DeclarationsBlock(lines: lines, cited: cited, extensionListings: extensionListings, printedExtensions: printedExtensions)
    }
}
