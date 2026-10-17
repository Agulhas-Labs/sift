//
// Copyright © Agulhas Labs
//

/// The answer for lines of a file asked for by range that resolve to two or more declarations within the source floor: the stretch of the file as written, under one header.
///
/// A block per declaration spends a header and a blank line on each, and leaves out what sits between the declarations — their doc comments, the blank lines, the comments that separate them — which is what a cited range of several one-line declarations asks for. The stretch runs from the range's first line, or the first declaration's where it starts above it, to the range's last line, or the last declaration's end where it runs past it. The header names the lines, the type they sit in where they share one and the stretch lies within its range, and how many declarations they hold.
struct RangeStretchAnswer {
    let renderer: DigestRenderer
    /// Every row of the file, where the shared parent is found.
    let rows: [SymbolRow]

    /// The stretch `range` asks of `blocks`, or `nil` where they are served as a block each: fewer than two, an offset to honour, or a stretch past the source floor or the end of the file.
    func answer(_ blocks: [SymbolRow], range: DigestLineRange, source: [String], options: DigestOptions) throws -> String? {
        guard blocks.count >= 2, options.offset == 0,
              let firstDeclared = blocks.map(\.line).min(), let lastDeclared = blocks.map(\.endLine).max()
        else {
            return nil
        }
        let first = max(1, min(range.start, firstDeclared))
        let last = max(range.end, lastDeclared)
        let lineCount = source.last == "" ? source.count - 1 : source.count
        guard last - first + 1 <= SourcePassthrough.floorLineCeiling, last <= lineCount else {
            return nil
        }
        let path = blocks[0].path
        let preamble = try renderer.parseErrorBanner(touching: [path]) + renderer.guessedModuleBanner(touching: [path])
        let header = try header(path: path, blocks: blocks, lines: first ... last)
        return (preamble + [header, ""] + source[(first - 1) ..< last]).joined(separator: "\n")
    }

    /// The line naming the stretch: its lines, and the type they are in where every declaration has the same one and the lines lie within that type's range.
    private func header(path: String, blocks: [SymbolRow], lines: ClosedRange<Int>) throws -> String {
        let named = "\(path) lines \(lines.lowerBound)-\(lines.upperBound)"
        let count = "(\(blocks.count) declarations)"
        guard let parentID = blocks[0].parentID, blocks.allSatisfy({ $0.parentID == parentID }),
              let parent = rows.first(where: { $0.id == parentID }),
              parent.line <= lines.lowerBound, lines.upperBound <= parent.endLine
        else {
            return "\(named) \(count)"
        }
        return try "\(named), in \(renderer.qualifiedTarget(of: parent)) — \(parent.kind.rawValue) — \(parent.rangeDescription) \(count)"
    }
}
