//
// Copyright © Agulhas Labs
//

import Foundation

extension WhereRenderer {
    /// One file's source lines, read for the text a store block's rows close on, and read only where the tree holds the file as the build saw it.
    ///
    /// A store position names a line as the build recorded it. In a file written since, that line may have moved, so the text now on it would be another line's: such a file, a deleted one, and one that cannot be read all give no text, and their rows print without it rather than with text that may be wrong.
    struct StoreSiteText {
        private let lines: [ArraySlice<UInt8>]

        /// Reads the file at `path`, absolute, where `state` says it stands as recorded.
        init(path: String, state: OccurrenceState) {
            guard state.isLive, let data = FileManager.default.contents(atPath: path) else {
                lines = []
                return
            }
            lines = [UInt8](data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        }

        /// Line `number`'s text as a row prints it (``NameMatchedSites/sourceText(_:)``), or `nil` where the file was not read or the line is past its end.
        func text(at number: Int) -> String? {
            guard lines.indices.contains(number - 1) else { return nil }
            guard let text = String(bytes: lines[number - 1], encoding: .utf8) else { return nil }
            return NameMatchedSites.sourceText(text)
        }
    }

    /// A store block's rows few enough to read in place: each file's `path (count):` heading, with the mark of a file changed since the build, then one row per recorded line, closing on the line's text.
    ///
    /// A row keeps what the compact form prints after its location — the caller or declaration, its access and its unit count — but a row folded by caller is listed once per line instead, as the name-matched blocks list theirs, so every row in the block is one recorded site and the heading's count is the rows'. Files keep the order the block gives them, the ones the tree still backs first; within a file, rows ascend by line.
    static func siteTextRows(
        _ ordered: [(entry: ListedRow, state: OccurrenceState)],
        relativePath: (String) -> String,
        shown: (SemanticStore.Hit) -> Void
    ) -> [String] {
        var paths: [String] = []
        var byPath: [String: [(entry: ListedRow, state: OccurrenceState)]] = [:]
        for row in ordered {
            if byPath[row.entry.hit.path] == nil {
                paths.append(row.entry.hit.path)
            }
            byPath[row.entry.hit.path, default: []].append(row)
        }
        var block: [String] = []
        for path in paths {
            let rows = (byPath[path] ?? []).enumerated()
                .sorted { ($0.element.entry.hit.line, $0.offset) < ($1.element.entry.hit.line, $1.offset) }
                .map(\.element)
            let state = rows.first?.state ?? .live
            let source = StoreSiteText(path: path, state: state)
            block.append("  \(relativePath(path)) (\(rows.count)):\(state.marker ?? "")")
            for row in rows {
                shown(row.entry.hit)
                let units = row.entry.units > 1 ? "  ×\(row.entry.units) units" : ""
                let access = row.entry.access.map { " — \($0)" } ?? ""
                block.append("    :\(row.entry.hit.line)  \(row.entry.hit.name)\(access)\(units)" + NameMatchedSites.textSuffix(source.text(at: row.entry.hit.line)))
            }
        }
        return block
    }
}
