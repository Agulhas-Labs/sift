//
// Copyright © Agulhas Labs
//

import Foundation

/// For each line range asked of one file, the lines its file digest prints for the members the range overlaps — what a line window is answered with where the file's whole digest is too large to hand over.
///
/// Every line it prints carries its member's range, so it still locates. A range in no member is answered as `File.swift:N` answers there: the container it is in and its nearest members, or, outside every declaration, the nearest top-level declarations.
struct WindowMembersAnswer {
    let renderer: DigestRenderer

    /// One answer per range, under the header of each type enclosing the members it overlaps, or `nil` where the index holds no file at `path`.
    func answers(overlapping ranges: [ClosedRange<Int>], inFile path: String, options: DigestOptions) throws -> [String]? {
        guard let file = try WalkedFile(renderer: renderer, path: path) else { return nil }
        let banner = try renderer.parseErrorBanner(touching: [file.row.path])
        return try ranges.map { range in
            let walk = file.walk(range)
            let asked = DigestLineRange(path: file.row.path, start: range.lowerBound, end: range.upperBound, suffix: "")
            let printed = try printedMembers(range, of: file, options: options)
            if !printed.members.isEmpty {
                return (banner + ["\(file.row.path) \(asked.spoken) \(range.count == 1 ? "is in" : "overlap"):"] + printed.members.map(\.text)).joined(separator: "\n")
            }
            if let gap = printed.gap {
                return try renderer.betweenMembersAnswer(asked, file: file.row, container: gap, walk: walk)
            }
            var outside = banner + ["(no declaration spans \(asked.spoken) in \(file.row.path)); the nearest:"]
            let before = file.topLevel.last { $0.endLine < range.lowerBound }
            let after = file.topLevel.first { walk.start(of: $0) > range.upperBound }
            for (label, row) in [("before", before), ("after", after)] {
                guard let row else { continue }
                try outside.append("  \(label): digest \(renderer.qualifiedTarget(of: row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
            }
            return outside.joined(separator: "\n")
        }
    }

    /// Whether every line of `range` lies in the doc comment directly above a declaration in the file at `path`, above that declaration's own first line — lines no member's digest line shows, since it carries a doc comment's summary at most.
    func liesInLeadingDocComment(_ range: ClosedRange<Int>, inFile path: String) throws -> Bool {
        guard case let .file(file) = try renderer.resolveFile(path: renderer.relativeToRepository(path) ?? path),
              let source = (try? String(contentsOf: renderer.repoRoot.appendingPathComponent(file.path), encoding: .utf8))?.components(separatedBy: "\n")
        else {
            return false
        }
        let walk = DigestRenderer.RangeWalk(span: range, children: [:], source: source)
        return try renderer.store.symbols(inFile: file.path).contains { row in
            walk.start(of: row) <= range.lowerBound && range.upperBound < row.line
        }
    }

    /// Whether any of `ranges` overlaps an `import` declaration's lines in the file at `path` — lines the file's digest accounts for on its `imports:` line, and a members answer does not.
    func overlapsImports(_ ranges: [ClosedRange<Int>], inFile path: String) throws -> Bool {
        guard case let .file(file) = try renderer.resolveFile(path: renderer.relativeToRepository(path) ?? path), !file.imports.isEmpty,
              let source = try? String(contentsOf: renderer.repoRoot.appendingPathComponent(file.path), encoding: .utf8)
        else {
            return false
        }
        let imports = ImportLines.of(source: source)
        return ranges.contains { range in imports.contains { $0.overlaps(range) } }
    }

    /// Whether the members answer for `range` would name exactly one member and nothing else — that member's declaration line (a wrapped signature's continuation lines with it) beneath the headers of the containers enclosing it, one per level — so it would show nothing of the lines themselves.
    ///
    /// A member whose answer carries a SwiftUI view outline is not one: the outline summarises what its lines build. Decided on what ``answers(overlapping:inFile:options:)`` would print, not on where the range lies: a range reaching past its member onto a blank, comment or brace line no answer shows is still one member, and a range whose answer names two or more members, or a container's header beside one, is not. A container's header counts as enclosing only where the range starts below the container's declaration line; a range taking in that line or its doc comment is reading the container, whose header its answer summarises.
    func namesOneMember(_ range: ClosedRange<Int>, inFile path: String, options: DigestOptions) throws -> Bool {
        guard let file = try WalkedFile(renderer: renderer, path: path) else { return false }
        let members = try printedMembers(range, of: file, options: options).members
        guard let named = members.last, !named.descends else { return false }
        // A view's outline — what its `body` builds, one row per element — is a summary of the lines, not the member's own line again.
        if !options.signaturesOnly, named.row.viewOutline?.isEmpty == false {
            return false
        }
        return members.enumerated().allSatisfy { index, member in
            member.depth == index && (index == members.count - 1 || member.descends && member.row.line < range.lowerBound)
        }
    }

    /// Whether the first page of the file's digest reaches every one of `ranges`: one page holds the whole digest, or each range ends above the first declaration the page leaves for a later one, its leading doc comment included — the listing runs in source order, so a page names nothing at or past that line.
    func firstPageReaches(_ ranges: [ClosedRange<Int>], inFile path: String, options: DigestOptions) throws -> Bool {
        guard let file = try WalkedFile(renderer: renderer, path: path) else { return false }
        let topLevel = try renderer.store.topLevelSymbols(inFileID: file.row.id)
        var outlineBudget = DigestRenderer.outlineCap
        let listed = try FileDigestMembers(renderer: renderer, topLevel: topLevel).budget(topLevel: topLevel, suites: nil, options: options, outlineBudget: &outlineBudget).filter(\.counted)
        guard listed.count > options.pageSize else { return true }
        guard let unlisted = listed[options.pageSize].row else { return false }
        return ranges.allSatisfy { $0.upperBound < file.walk($0).start(of: unlisted) }
    }

    /// Whether the file's digest lists on a line of its own, and so with its line range, every member the members answer for each of `ranges` would name.
    ///
    /// The file's digest names a nested type's members on that type's line without their lines, so it places none of what a window over them prints. Whether a page reaches them is ``firstPageReaches(_:inFile:options:)``'s to say.
    func placesEveryMember(_ ranges: [ClosedRange<Int>], inFile path: String, options: DigestOptions) throws -> Bool {
        guard let file = try WalkedFile(renderer: renderer, path: path) else { return false }
        let topLevel = try renderer.store.topLevelSymbols(inFileID: file.row.id)
        var outlineBudget = DigestRenderer.outlineCap
        let listed = try Set(FileDigestMembers(renderer: renderer, topLevel: topLevel).budget(topLevel: topLevel, suites: nil, options: options, outlineBudget: &outlineBudget).compactMap(\.row?.id))
        return try ranges.allSatisfy { range in
            try printedMembers(range, of: file, options: options).members.allSatisfy { listed.contains($0.row.id) }
        }
    }
}

private extension WindowMembersAnswer {
    /// One line a members answer prints: the member, how deeply it is nested, whether the members beneath it are walked in turn, and its rendered text.
    struct PrintedMember {
        let row: SymbolRow
        let depth: Int
        let descends: Bool
        let text: String
    }

    /// The indexed file a members answer walks: its row, its top-level declarations, every container's members, and its source lines.
    struct WalkedFile {
        let row: FileRow
        let topLevel: [SymbolRow]
        let children: [Int64: [SymbolRow]]
        let source: [String]

        /// The file at `path` as the index holds it, or `nil` where it holds no file there.
        init?(renderer: DigestRenderer, path: String) throws {
            guard case let .file(file) = try renderer.resolveFile(path: renderer.relativeToRepository(path) ?? path) else { return nil }
            let rows = try renderer.store.symbols(inFile: file.path)
            row = file
            source = (try? String(contentsOf: renderer.repoRoot.appendingPathComponent(file.path), encoding: .utf8))?
                .components(separatedBy: "\n") ?? []
            children = Dictionary(grouping: rows.filter { $0.parentID != nil }) { $0.parentID ?? 0 }
            topLevel = WindowMembersAnswer.inOrder(rows.filter { $0.parentID == nil })
        }

        func walk(_ range: ClosedRange<Int>) -> DigestRenderer.RangeWalk {
            DigestRenderer.RangeWalk(span: range, children: children, source: source)
        }
    }

    static func inOrder(_ rows: [SymbolRow]) -> [SymbolRow] {
        rows.sorted { ($0.line, $0.id) < ($1.line, $1.id) }
    }

    /// The members `range` overlaps, in the order and at the depth the members answer prints them, and the container whose members it falls between where it overlaps none.
    func printedMembers(_ range: ClosedRange<Int>, of file: WalkedFile, options: DigestOptions) throws -> (members: [PrintedMember], gap: SymbolRow?) {
        let walk = file.walk(range)
        let overlaps = { (row: SymbolRow) in walk.start(of: row) <= range.upperBound && range.lowerBound <= row.endLine }
        var outlineBudget = DigestRenderer.outlineCap
        var printed: [PrintedMember] = []
        var gap: SymbolRow?
        // Walks down every level of nesting the range overlaps, as `RangeWalk` does for a single-declaration
        // answer: a container whose overlapping members are themselves containers is not the innermost row
        // the range falls in, so its header is printed and its overlapping members are walked in turn, all
        // the way down to the members that actually enclose the range.
        func render(_ rows: [SymbolRow], depth: Int) throws {
            for row in rows where overlaps(row) {
                let members = Self.inOrder(file.children[row.id] ?? [])
                let inside = members.filter(overlaps)
                if row.kind.isContainer, !members.isEmpty, inside.isEmpty {
                    gap = gap ?? row
                    continue
                }
                let descends = row.kind.isContainer && !inside.isEmpty
                let indent = String(repeating: " ", count: depth * 4)
                let text = try renderer.containerAwareLine(row, options: options, indent: indent, outlineBudget: &outlineBudget, namingChildren: !descends)
                printed.append(PrintedMember(row: row, depth: depth, descends: descends, text: text))
                if descends {
                    try render(inside, depth: depth + 1)
                }
            }
        }
        try render(file.topLevel, depth: 0)
        return (printed, gap)
    }
}
