//
// Copyright © Agulhas Labs
//

import Foundation

/// A hunk of the line diff that no declaration change and no text outside the declarations accounts for — named for what it is where that can be read off its bytes, and otherwise said to be there.
///
/// The safety net under `diff`'s structural pass. Whatever category of change the pass has no name for yet, git still sees the lines differ; a hunk that meets no reported entry is listed here with its lines, so nothing that changed can read as unchanged.
struct LineChange: Sendable, Equatable {
    let kind: Kind
    /// The hunk's before-side lines, `nil` for a pure insertion.
    let old: DeclarationRange?
    /// The hunk's after-side lines, `nil` for a pure deletion.
    let new: DeclarationRange?
}

extension LineChange {
    enum Kind: Sendable, Equatable {
        /// A byte-order mark added to (or taken from) the first line, and nothing else.
        case byteOrderMark(added: Bool)
        /// Line terminators and nothing else — with the direction, where every changed terminator went the same way.
        case lineEndings(String)
        /// Spaces, tabs and blank lines, and nothing else.
        case whitespace
        /// The same characters in another Unicode normalization — equal to Swift's `String`, different bytes to git.
        case normalization
        /// Something no category above describes: named only by its lines.
        case unnamed
    }

    /// Names one uncovered hunk from the bytes of the lines in it that are left to explain — `old` and `new` are those lines' indices on each side.
    ///
    /// A byte-order mark on the first line is set aside first: it is named once for the whole file (``byteOrderMark(old:new:)``), so a hunk that holds nothing else is ``Kind/byteOrderMark(added:)`` and needs no line of its own.
    static func classify(_ hunk: LineDiff.Hunk, lines: (old: [Data], new: [Data]), left: (old: [Int], new: [Int])) -> LineChange {
        let unmarked: (Int, Data) -> Data = { index, line in index == 0 && line.starts(with: mark) ? line.dropFirst(mark.count) : line }
        let before = Data(left.old.flatMap { unmarked($0, lines.old[$0]) })
        let after = Data(left.new.flatMap { unmarked($0, lines.new[$0]) })
        let hadMark = left.old.first == 0 && lines.old[0].starts(with: mark)
        let hasMark = left.new.first == 0 && lines.new[0].starts(with: mark)
        let named: Kind = hadMark != hasMark && before == after ? .byteOrderMark(added: hasMark) : kind(before: before, after: after)
        return LineChange(kind: named, old: hunk.oldLines, new: hunk.newLines)
    }

    private static var mark: Data {
        Data([0xEF, 0xBB, 0xBF])
    }

    /// A byte-order mark added to or taken from the file — named once for the file, whatever else changed on its first line.
    static func byteOrderMark(old: Data?, new: Data?) -> LineChange? {
        guard let old, let new, old.starts(with: mark) != new.starts(with: mark) else { return nil }
        let first = DeclarationRange(line: 1, endLine: 1)
        return LineChange(kind: .byteOrderMark(added: new.starts(with: mark)), old: first, new: first)
    }

    private static func kind(before: Data, after: Data) -> Kind {
        let folded = (before: folding(before), after: folding(after))
        if folded.before == folded.after {
            let crlfBefore = crlfCount(before)
            let crlfAfter = crlfCount(after)
            let direction = crlfAfter == 0 ? " (CRLF → LF)" : crlfBefore == 0 ? " (LF → CRLF)" : ""
            return .lineEndings(direction)
        }
        if folded.before.filter({ !isWhitespace($0) }) == folded.after.filter({ !isWhitespace($0) }) {
            return .whitespace
        }
        if let text = String(data: before, encoding: .utf8), let other = String(data: after, encoding: .utf8), text == other {
            return .normalization
        }
        return .unnamed
    }

    private static func folding(_ data: Data) -> [UInt8] {
        var folded: [UInt8] = []
        folded.reserveCapacity(data.count)
        for byte in data {
            if byte == 0x0A, folded.last == 0x0D {
                folded.removeLast()
            }
            folded.append(byte)
        }
        return folded
    }

    private static func crlfCount(_ data: Data) -> Int {
        zip(data, data.dropFirst()).count { $0 == 0x0D && $1 == 0x0A }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }
}
