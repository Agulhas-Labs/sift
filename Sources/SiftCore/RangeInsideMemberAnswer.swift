//
// Copyright © Agulhas Labs
//

/// The answer for lines of a file asked for by range that lie inside one long member: those lines alone, under one header naming the member and its whole range.
///
/// Serving a long member whole for a few lines inside it hands back many times what was asked — the ranged read a cited location replaces would have been the smaller answer. The lines are paged like a member body, by the same range and an offset. A single line asked for is the question a stack trace or a log line puts — which function is this in — so it comes beneath the member's declaration with a few lines either side, and a last line naming the range to read for the rest.
struct RangeInsideMemberAnswer {
    let renderer: DigestRenderer

    /// Lines either side of a single line asked for inside a long member: enough to read the line in its place, where the whole member says far more than was asked.
    static var lineWindowContext: Int {
        3
    }

    /// The longest member a single line inside is served whole from: past it, the declaration and the line's window answer which function the line is in for a fraction of the member.
    static var singleLineMemberCeiling: Int {
        25
    }

    /// The lines `range` asks of `row`, or `nil` where the member is served whole as before: when it is within the ceiling for what was asked (`singleLineMemberCeiling` for one line, the source floor for a range), when the lines reach past it, or when they cover all of it.
    func answer(_ row: SymbolRow, range: DigestLineRange, walk: DigestRenderer.RangeWalk, source: [String], options: DigestOptions) throws -> String? {
        let memberStart = walk.start(of: row)
        let memberLines = row.endLine - row.line + 1
        let single = range.start == range.end
        guard memberLines > (single ? Self.singleLineMemberCeiling : SourcePassthrough.floorLineCeiling),
              memberStart <= range.start, range.end <= row.endLine,
              row.line < range.start || range.end < row.endLine,
              row.endLine <= source.count
        else {
            return nil
        }
        let plain = single
            ? max(memberStart, range.start - Self.lineWindowContext) ... min(row.endLine, range.end + Self.lineWindowContext)
            : range.start ... range.end
        let signatureEnd = single && plain.upperBound >= row.line ? SignatureExtent(of: row, in: source)?.lastLine ?? row.line : row.line
        let window = Self.holdingAllOrNone(of: row.line ... signatureEnd, plain)
        let target = try renderer.qualifiedTarget(of: row)
        let asked = single
            ? "lines \(window.lowerBound)-\(window.upperBound) (line \(range.start) with \(window == plain ? "" : "the declaration and ")up to \(Self.lineWindowContext) lines either side)"
            : range.spoken
        let header = "\(row.path) \(asked), in \(target) — \(row.kind.rawValue) — \(row.rangeDescription) (\(memberLines) lines; digest \(target) for all of it)"
        let all = Array(source[(window.lowerBound - 1) ..< window.upperBound])
        let cap = DigestRenderer.bodyLineCap
        let offset = min(max(0, options.offset), all.count)
        var body = Array(all.dropFirst(offset).prefix(cap))
        if offset > 0, !single {
            body.insert("(…\(offset) lines skipped)", at: 0)
        }
        let remaining = all.count - offset - min(cap, all.count - offset)
        if remaining > 0 {
            let resume = options.spelling.digest(range.path + range.suffix, offset: offset + cap)
            body.append("… truncated: \(remaining) more lines — \(resume), or Read \(row.path) from line \(window.lowerBound + offset + cap)")
        }
        if single {
            body = Self.framed(body, skipped: offset, of: row, through: signatureEnd, lines: window, source: source)
        }
        let preamble = try renderer.parseErrorBanner(touching: [row.path]) + renderer.guessedModuleBanner(touching: [row.path])
        return (preamble + [header, ""] + body).joined(separator: "\n")
    }
}

private extension RangeInsideMemberAnswer {
    /// A single line's window with the member's declaration and the range that reads the rest: the declaration beneath the window where it ends in the doc comment above the declaration, above it where the page starts below the declaration's first line, and not again where it already shows it.
    ///
    /// The declaration is laid out as the member's digest line lays it out, so a long parameter list wraps at its parameters rather than running off the line. It stands for the member's lines through `signatureEnd`, so a page offset never cuts it short; the page offset and the gap to the declaration are one marker where they meet.
    static func framed(_ window: [String], skipped offset: Int, of row: SymbolRow, through signatureEnd: Int, lines: ClosedRange<Int>, source: [String]) -> [String] {
        func marker(_ count: Int) -> [String] {
            count > 0 ? ["(…\(count) lines skipped)"] : []
        }
        let indent = String(source[row.line - 1].prefix { $0 == " " || $0 == "\t" })
        let declaration = (DigestSignatureLayout(SourceSlicer.tidyingBrackets(in: row.signature))?.lines ?? [SourceSlicer.shown(row.signature)]).map { indent + $0 }
        var framed: [String]
        let first = lines.lowerBound + offset
        if lines.upperBound < row.line {
            let gap = row.line - lines.upperBound - 1
            framed = window.isEmpty
                ? marker(offset + gap) + declaration
                : marker(offset) + window + marker(gap) + declaration
        } else if first > row.line {
            let resumed = max(first, signatureEnd + 1)
            framed = marker(row.line - lines.lowerBound) + declaration + marker(resumed - signatureEnd - 1) + window.dropFirst(resumed - first)
        } else {
            framed = marker(offset) + window
        }
        return framed + ["lines \(row.line)-\(row.endLine); read it by range"]
    }

    /// `window` widened to hold all of `head`, the lines of the member's declaration, where it holds part of it; as it is where it holds all or none.
    static func holdingAllOrNone(of head: ClosedRange<Int>, _ window: ClosedRange<Int>) -> ClosedRange<Int> {
        guard window.overlaps(head) else {
            return window
        }
        return min(window.lowerBound, head.lowerBound) ... max(window.upperBound, head.upperBound)
    }
}
