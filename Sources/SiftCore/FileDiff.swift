//
// Copyright © Agulhas Labs
//

import Foundation

/// One touched Swift file, compared: what happened to it, its declaration changes, every change outside its declarations, and every line the line diff saw change that neither accounts for.
///
/// Built the moment both sides are parsed and kept in place of them — a whole range's sources are never held at once, only these.
struct FileDiff: Sendable {
    let path: String
    let status: Status
    /// The sides git has that are not UTF-8 text, so there is nothing to parse — `nil` for a file that was read and broken down.
    let unreadableSides: String?
    let lineStat: GitContext.LineStat?
    let changes: [DeclarationChange]
    let outside: [OutsideChange]
    /// The line diff's hunks that no entry above meets, each named for what it is where its bytes say — the safety net, so nothing git sees change goes without a line in the answer.
    let lineChanges: [LineChange]
    /// Both sides read, and byte for byte the same — a rename or a mode change and nothing else.
    let identical: Bool
    let oldImports: [String]
    let newImports: [String]
    /// Sides that parsed with errors, so their declarations may be short (Docs/AnswerContract.md §6).
    let parseErrorSides: [String]
}

extension FileDiff {
    enum Status: Sendable, Equatable {
        case added, deleted, modified
        case renamed(from: String)
        /// Deleted in the index but still on disk, untracked — `git rm --cached` — so the working tree still holds what `HEAD` does.
        case untrackedNow
    }

    /// Compares one file's two sides as git holds them, `nil` where the file does not exist on that side.
    ///
    /// "Identical" is decided on the bytes, never on decoded text: decoding drops a byte-order mark, and Swift's string equality calls two spellings of one accented letter the same. `keepsBody` picks the declarations whose bodies are kept — only the one a `--member` answer names.
    static func compare(
        path: String,
        status: Status,
        lineStat: GitContext.LineStat?,
        bytes: (old: Data?, new: Data?),
        keepsBody: @escaping (DeclarationChange) -> Bool = { _ in false }
    ) -> FileDiff {
        let sources = (old: bytes.old.flatMap { String(data: $0, encoding: .utf8) }, new: bytes.new.flatMap { String(data: $0, encoding: .utf8) })
        let unreadable = [(bytes.old, sources.old, "before"), (bytes.new, sources.new, "after")].filter { $0.0 != nil && $0.1 == nil }.map(\.2)
        guard unreadable.isEmpty else {
            return FileDiff(
                path: path,
                status: status,
                unreadableSides: unreadable.joined(separator: " and "),
                lineStat: lineStat,
                changes: [],
                outside: [],
                lineChanges: [],
                identical: false,
                oldImports: [],
                newImports: [],
                parseErrorSides: []
            )
        }
        let oldSide = sources.old.map { DiffFileSide.parse(source: $0, path: path) }
        let newSide = sources.new.map { DiffFileSide.parse(source: $0, path: path) }
        let oldLines = bytes.old.map(LineDiff.lines) ?? []
        let newLines = bytes.new.map(LineDiff.lines) ?? []
        let hunks = LineDiff.hunks(old: oldLines, new: newLines)
        let declarations = DeclarationDiff.compare(old: oldSide, new: newSide, hunks: hunks, keepingBodiesOf: keepsBody)
        var changes = declarations.changes
        let pairs = declarations.pairs
        let extents = declarations.extents
        let outside = OutsideChange.between(old: oldSide?.outside, new: newSide?.outside, hunks: hunks)
        let spans = changes.flatMap(\.spans) + outside.flatMap(\.spans)
        let uncovered = hunks.filter { hunk in !spans.contains { hunk.meets(old: $0.old, new: $0.new) } }
        // A byte-order mark is a fact about the file, named once whatever else changed on its first line.
        var lineChanges = LineChange.byteOrderMark(old: bytes.old, new: bytes.new).map { [$0] } ?? []
        var extentsMet: [Int] = []
        for hunk in uncovered {
            guard let left = unexplained(hunk, lines: (oldLines, newLines), pairs: pairs) else { continue }
            let named = LineChange.classify(hunk, lines: (oldLines, newLines), left: left)
            if case .byteOrderMark = named.kind {
                continue
            }
            // Lines that are a type's own — its header, its closing brace — and not whitespace alone: where it opens
            // or closes moved, and that type is the change.
            let met = extents.indices.filter { index in extents[index].spans.contains { hunk.meets(old: $0.old, new: $0.new) } }
            if named.kind == .unnamed, !met.isEmpty {
                extentsMet += met.filter { !extentsMet.contains($0) }
                continue
            }
            lineChanges.append(named)
        }
        changes += extentsMet.sorted().map { extents[$0] }
        var parseErrorSides: [String] = []
        if let oldSide, oldSide.file.parseErrorCount > 0 {
            parseErrorSides.append("before")
        }
        if let newSide, newSide.file.parseErrorCount > 0 {
            parseErrorSides.append("after")
        }
        return FileDiff(
            path: path,
            status: status,
            unreadableSides: nil,
            lineStat: lineStat,
            changes: changes,
            outside: outside,
            lineChanges: lineChanges,
            identical: bytes.old != nil && bytes.old == bytes.new,
            oldImports: oldSide?.file.imports ?? [],
            newImports: newSide?.file.imports ?? [],
            parseErrorSides: parseErrorSides
        )
    }

    /// Whether anything in this file is reported beyond its heading — declarations, text outside them, or lines the line diff saw.
    var reportsChanges: Bool {
        !changes.isEmpty || !outside.isEmpty || !lineChanges.isEmpty
    }

    /// The lines of an uncovered hunk left to explain once the lines of unchanged declarations are set aside — `nil` when none are left.
    ///
    /// A line diff may show a declaration whose text did not change as deleted in one place and inserted in another — which of two equally short alignments it picks is an implementation detail (git's own, or a `diff.algorithm` a reader has configured, may pick the other). A declaration present on both sides whose whole lines are byte for byte the same, and whose place among its siblings did not change (a reorder is reported as a move), has not changed; its lines in a hunk are that hunk's alignment, and are set aside. Whatever else is in the hunk is still explained or named.
    private static func unexplained(
        _ hunk: LineDiff.Hunk,
        lines: (old: [Data], new: [Data]),
        pairs: [(old: DeclarationRange, new: DeclarationRange)]
    ) -> (old: [Int], new: [Int])? {
        let intact = pairs.filter { pair in
            hunk.meets(old: pair.old, new: pair.new) && pair.old.endLine - pair.old.line == pair.new.endLine - pair.new.line
                && pair.old.line >= 1 && pair.new.line >= 1 && pair.old.endLine <= lines.old.count && pair.new.endLine <= lines.new.count
                && lines.old[(pair.old.line - 1) ..< pair.old.endLine].elementsEqual(lines.new[(pair.new.line - 1) ..< pair.new.endLine])
        }
        let old = hunk.old.filter { index in !intact.contains { $0.old.line - 1 <= index && index < $0.old.endLine } }
        let new = hunk.new.filter { index in !intact.contains { $0.new.line - 1 <= index && index < $0.new.endLine } }
        return old.isEmpty && new.isEmpty ? nil : (old, new)
    }
}

extension OutsideChange {
    /// The lines each reported fragment answers for, on the side it is reported for.
    var spans: [(old: DeclarationRange?, new: DeclarationRange?)] {
        let range: (Fragment) -> DeclarationRange = { DeclarationRange(line: $0.line, endLine: max($0.line, $0.endLine)) }
        return removed.map { (range($0), nil) } + added.map { (nil, range($0)) } + edited.map { (range($0.old), range($0.new)) }
    }
}

extension DeclarationChange {
    /// The lines this entry answers for, one side at a time.
    var spans: [(old: DeclarationRange?, new: DeclarationRange?)] {
        oldSpans.map { ($0, nil) } + newSpans.map { (nil, $0) }
    }
}
