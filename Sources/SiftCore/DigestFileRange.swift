//
// Copyright © Agulhas Labs
//

import Foundation

// MARK: - File digest by line range

/// `File.swift:12`, `File.swift:12-40`, or `File.swift:12:5` as a digest target — the shape a `where` answer or a stack trace hands back rather than a name.
///
/// **What the lines resolve to**, walking the file's declarations from the top:
/// - A declaration the lines cover whole is served as one block, its own header and the comments between its members included — so `:10-549` of a type is that type, not each of its members one by one.
/// - A declaration they only partly cover is served whole if it is a leaf within the source floor, and looked inside if it is a container. A longer leaf that holds every line asked for serves only those lines, under one header naming it and its whole range. A single line inside a leaf longer than `RangeInsideMemberAnswer.singleLineMemberCeiling` comes as its window: the line with `RangeInsideMemberAnswer.lineWindowContext` lines either side, numbered as Read numbers them with the cited line marked, under the one header naming the leaf and its whole range, with no declaration or footer repeating what the header says.
/// - A line in a declaration's doc comment belongs to that declaration, and its attributes already sit inside its range. The declaration is served with the doc-comment lines the range covers: its block starts at the first of them the range reaches, and at its own first line where the range starts below it.
/// - Two or more declarations the lines resolve to, within the source floor, are served as one stretch of the file as written — doc comments, blank lines and the comments between declarations included — under one header, by `RangeStretchAnswer`. Past the floor, or with an offset, each is a block of its own.
/// - Rows sharing one range — cases packed on one line — are one declaration's worth of source, served once, under the first of them.
/// - Lines inside a container that belong to none of its members — a blank line, a comment, the container's own header — are answered with the nearest members before and after, named with their ranges; the container itself is served only when it is small enough for the compression floor to have served it anyway.
/// - Lines no declaration reaches at all get the file's own digest and one line saying so.
extension DigestRenderer {
    /// What a line range resolved to.
    enum RangeResolution {
        /// Declarations to serve, in order.
        case blocks([SymbolRow])
        /// Lines inside this container that none of its members reaches.
        case between(SymbolRow)
        /// Lines no declaration reaches.
        case outside
    }

    /// `lines`, which open at `first`, with the file's lines from `reaching` down to `first` put in front, or `lines` as they are where `reaching` is not above `first`.
    ///
    /// A range that covers a declaration's doc comment serves it with the declaration, so the lines above the declaration's own first line join its block; the Read advice a truncation names counts from the line the block opens on.
    func leading(_ lines: [String], from first: Int, reaching: Int?, of row: SymbolRow) -> ([String], Int) {
        guard let reaching, reaching >= 1, reaching < first,
              let text = sourceReader.text(of: row.path, under: repoRoot)
        else {
            return (lines, first)
        }
        let file = text.components(separatedBy: "\n")
        guard first - 1 <= file.count else { return (lines, first) }
        return (Array(file[(reaching - 1) ..< (first - 1)]) + lines, reaching)
    }

    /// `File.swift:12-40` resolved and rendered — see the extension's own summary for what the lines resolve to.
    func renderFileRange(_ range: DigestLineRange, options: DigestOptions) throws -> MeasuredAnswer {
        let file: FileRow
        switch try resolveFile(path: relativeToRepository(range.path) ?? range.path) {
        case let .file(row):
            file = row
        case let .ambiguous(candidates):
            return MeasuredAnswer(text: ambiguousFileAnswer(path: range.path, candidates: candidates, suffix: range.suffix))
        case .missing:
            let resolution = unindexedFileAnswer(path: range.path)
            return MeasuredAnswer(text: resolution.text, missed: !resolution.excluded)
        }
        let rows = try store.symbols(inFile: file.path)
        let source = sourceReader.text(of: file.path, under: repoRoot)?.components(separatedBy: "\n") ?? []
        let children = Dictionary(grouping: rows.filter { $0.parentID != nil }) { $0.parentID ?? 0 }
        let walk = RangeWalk(span: range.start ... range.end, children: children, source: source)

        switch walk.resolve(among: rows.filter { $0.parentID == nil }) {
        case .outside:
            let digest = try renderFile(path: range.path, options: options)
            // The verdict leads (Docs/AnswerContract.md §2): a reader who stops at the first line already
            // knows nothing here spans the lines asked for, before ever reaching the file digest it fell back to.
            return MeasuredAnswer(text: "(no declaration spans \(range.spoken) in \(file.path))\n\n" + digest.text, bytes: digest.bytes)
        case let .between(container) where container.endLine - container.line + 1 <= SourcePassthrough.floorLineCeiling:
            return try MeasuredAnswer(text: memberSource(of: container, target: qualifiedTarget(of: container), options: options))
        case let .between(container):
            var answer = try betweenMembersAnswer(range, file: file, container: container, walk: walk)
            // A short list of neighbours is one page, so an offset has nothing here to skip. It is served anyway,
            // with the offset named as unused: unlike several blocks, one answer leaves no doubt what the offset
            // was meant to page, and dropping it in silence would read as having honoured it.
            if options.offset > 0 {
                answer += "\n(offset \(options.offset) unused — this answer is a single page)"
            }
            return MeasuredAnswer(text: answer)
        case let .blocks(blocks):
            if blocks.count == 1, let lines = try RangeInsideMemberAnswer(renderer: self).answer(blocks[0], range: range, walk: walk, source: source, options: options) {
                return MeasuredAnswer(text: lines)
            }
            if let stretch = try RangeStretchAnswer(renderer: self, rows: rows).answer(blocks, range: range, source: source, options: options) {
                return MeasuredAnswer(text: stretch)
            }
            guard blocks.count == 1 || options.offset == 0 else {
                throw EngineError.offsetAcrossSeveralDeclarations(target: range.path + range.suffix, count: blocks.count)
            }
            // Beside other blocks, a truncated one names its own exact range as the call that pages it: those
            // lines cover that declaration whole and nothing else, so they resolve to it alone, and an offset
            // on one block is honoured where the range that produced several refuses it.
            let bodies = try blocks.map { row in
                // A block opens at the first of its doc-comment lines the range reaches, never below its own line.
                let first = min(row.line, max(range.start, walk.start(of: row)))
                return try memberSource(
                    of: row,
                    target: qualifiedTarget(of: row),
                    options: options,
                    resumeTarget: blocks.count > 1 ? "\(file.path):\(first)-\(row.endLine)" : nil,
                    from: first
                )
            }
            return MeasuredAnswer(text: Self.joinedAnswers(bodies))
        }
    }
}

extension DigestRenderer {
    /// One line range walked down a file's declarations — the rules are `renderFileRange`'s.
    struct RangeWalk {
        let span: ClosedRange<Int>
        let children: [Int64: [SymbolRow]]
        let source: [String]

        /// The first line that belongs to `row`: its own first line, or the first line of the doc comment directly above it.
        func start(of row: SymbolRow) -> Int {
            var first = row.line
            while first > 1, first - 2 < source.count {
                let above = source[first - 2].trimmingCharacters(in: .whitespaces)
                if above.hasPrefix("///") {
                    first -= 1
                } else if above.hasSuffix("*/"), let opening = blockCommentOpening(endingAt: first - 1), source[opening - 1].contains("/**") {
                    first = opening
                } else {
                    break
                }
            }
            return first
        }

        /// The line a block comment ending at `line` opens on, or `nil` when none opens above it.
        private func blockCommentOpening(endingAt line: Int) -> Int? {
            var candidate = line
            while candidate >= 1 {
                if source[candidate - 1].contains("/*") {
                    return candidate
                }
                candidate -= 1
            }
            return nil
        }

        /// What the span resolves to among these siblings, in the order they are declared.
        fileprivate func resolve(among siblings: [SymbolRow]) -> DigestRenderer.RangeResolution {
            var blocks: [SymbolRow] = []
            var gap: SymbolRow?
            for row in siblings.sorted(by: { ($0.line, $0.id) < ($1.line, $1.id) })
                where start(of: row) <= span.upperBound && span.lowerBound <= row.endLine
            {
                if span.lowerBound <= row.line, row.endLine <= span.upperBound {
                    blocks.append(row)
                } else if row.kind.isContainer {
                    switch resolve(among: children[row.id] ?? []) {
                    case let .blocks(inner): blocks += inner
                    case let .between(inner): gap = gap ?? inner
                    case .outside: gap = gap ?? row
                    }
                } else {
                    blocks.append(row)
                }
            }
            // Rows sharing one range are one stretch of source: `case a, b, c` is three rows on one line.
            var seen: Set<[Int]> = []
            blocks = blocks.filter { seen.insert([$0.line, $0.endLine]).inserted }
            if !blocks.isEmpty {
                return .blocks(blocks)
            }
            return gap.map(DigestRenderer.RangeResolution.between) ?? .outside
        }
    }
}
