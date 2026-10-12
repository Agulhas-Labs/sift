//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftOperators
import SwiftSyntax

/// What one parse of a file gives the timing rows that name it: the parsed file, the `deinit` around each row's line, and each expression row's shape, read before the tree is dropped.
struct BuildTimingFileReading {
    let file: ParsedFile?
    let deinitializers: [Int: BuildTimingDeinitializers.Found]
    let shapes: [Position: String]

    /// Reads and parses `path` under the tree root for `rows`, or holds nothing where it cannot be read as UTF-8.
    init(_ path: String, for rows: [BuildTimingRow], under treeRoot: URL) {
        guard let data = try? Data(contentsOf: treeRoot.appendingPathComponent(path)),
              let source = String(data: data, encoding: .utf8)
        else {
            (file, deinitializers, shapes) = (nil, [:], [:])
            return
        }
        let (file, found) = FileParser.parse(source: source, repoRelativePath: path) { tree, converter in
            // Sequence expressions arrive flat, precedence unresolved; folded once here so a `+` chain or a
            // ternary chain reads as the nested tree it is, rather than a sequence no shape can be read off.
            let folded = OperatorTable.standardOperators.foldAll(tree) { _ in }.as(SourceFileSyntax.self) ?? tree
            var deinitializers: [Int: BuildTimingDeinitializers.Found] = [:]
            var shapes: [Position: String] = [:]
            for row in rows {
                deinitializers[row.line] = BuildTimingDeinitializers.range(containing: row.line, in: folded, converter: converter)
                if row.kind == .expression {
                    shapes[Position(line: row.line, column: row.column)] = BuildTimingExpressionShape.name(atLine: row.line, column: row.column, in: folded, converter: converter)
                }
            }
            return (deinitializers, shapes)
        }
        (self.file, deinitializers, shapes) = (file, found.0, found.1)
    }
}

extension BuildTimingFileReading {
    /// A row's line and column, which its shape is keyed by.
    struct Position: Hashable {
        let line: Int
        let column: Int
    }
}
