//
// Copyright © Agulhas Labs
//

/// The answer for lines of a file asked for by range that lie inside one long member: those lines alone, under one header naming the member and its whole range.
///
/// Serving a long member whole for a few lines inside it hands back many times what was asked — the ranged read a cited location replaces would have been the smaller answer. The lines are paged like a member body, by the same range and an offset. A single line asked for is the question a stack trace or a log line puts — which function is this in — so it is those lines with 3 either side, numbered as Read numbers them (the number right-aligned to 6 columns, a tab, the source line; the cited line marked with `>` for the first padding space), under the header that names the member and its whole range, with no declaration, skip markers or footer repeating what the header says.
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
        let window = single
            ? max(memberStart, range.start - Self.lineWindowContext) ... min(row.endLine, range.end + Self.lineWindowContext)
            : range.start ... range.end
        let target = try renderer.qualifiedTarget(of: row)
        let asked = single
            ? "lines \(window.lowerBound)-\(window.upperBound) (line \(range.start) with up to \(Self.lineWindowContext) lines either side)"
            : range.spoken
        let header = "\(row.path) \(asked), in \(target) — \(row.kind.rawValue) — \(row.rangeDescription) (\(memberLines) lines; digest \(target) for all of it)"
        let all = Array(source[(window.lowerBound - 1) ..< window.upperBound])
        let cap = DigestCaps.bodyLineCap
        if PastEndLine.applies(offset: options.offset, count: all.count) {
            let preamble = try renderer.parseErrorBanner(touching: [row.path]) + renderer.guessedModuleBanner(touching: [row.path])
            return (preamble + [header, "", PastEndLine.text(offset: options.offset, count: all.count, noun: "body lines")]).joined(separator: "\n")
        }
        let offset = min(max(0, options.offset), all.count)
        var body = Array(all.dropFirst(offset).prefix(cap))
        if single {
            body = Self.numbered(body, from: window.lowerBound + offset, cited: range.start)
        } else if offset > 0 {
            body.insert("(…\(offset) lines skipped)", at: 0)
        }
        let remaining = all.count - offset - min(cap, all.count - offset)
        if remaining > 0 {
            let resume = options.spelling.digest(range.path + range.suffix, offset: offset + cap)
            body.append("… truncated: \(remaining) more lines — \(resume), or Read \(row.path) from line \(window.lowerBound + offset + cap)")
        }
        let preamble = try renderer.parseErrorBanner(touching: [row.path]) + renderer.guessedModuleBanner(touching: [row.path])
        return (preamble + [header, ""] + body).joined(separator: "\n")
    }
}

private extension RangeInsideMemberAnswer {
    /// The page's lines laid out as Claude Code's Read lays them out, so the cited line is told from its neighbours without a Read of the same lines.
    ///
    /// Each line's number is right-aligned to `numberWidth`, then a tab, then the source line. The cited line has `>` in place of its number's leading padding character, or before the number where it has none.
    static func numbered(_ page: [String], from first: Int, cited: Int) -> [String] {
        var lineNumber = first - 1
        return page.map { line in
            lineNumber += 1
            let digits = String(lineNumber)
            let padded = String(repeating: " ", count: max(0, numberWidth - digits.count)) + digits
            let label = lineNumber == cited ? (padded.hasPrefix(" ") ? ">" + padded.dropFirst() : ">" + padded) : padded
            return label + "\t" + line
        }
    }

    /// The width a line number is right-aligned to, as Read aligns it.
    static var numberWidth: Int {
        6
    }
}
