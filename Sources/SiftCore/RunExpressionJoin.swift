//
// Copyright © Agulhas Labs
//

import Foundation

/// A failure's message, or one of its `↳` lines, whose brackets do not balance, while the indented lines beneath it carry the rest of the expression.
///
/// Swift Testing prints an `#expect` written over several lines as it was written, so `RunOutputFilter` holds the first line here and joins each continuation to it until the brackets balance, the note-line cap is reached or a line that is no continuation arrives.
struct RunExpressionJoin {
    /// The failure the expression belongs to, by its index in the filter's list.
    let index: Int
    /// Whether the expression is a `↳` line of the note rather than the failure's message.
    let inNote: Bool
    private(set) var text: String
    /// How many brackets the text still owes.
    private(set) var depth: Int
    /// How many continuation lines have been joined so far.
    private(set) var lines = 0
    /// The depth the first line was printed at, as the whitespace ``RunExpansionDepth`` keeps; empty for a message.
    var indent = ""

    /// A join over `text`, or `nil` where its brackets balance and nothing beneath it is owed.
    static func opening(_ text: String, index: Int, inNote: Bool, indent: String = "") -> RunExpressionJoin? {
        let depth = bracketDepth(of: text)
        return depth > 0 ? RunExpressionJoin(index: index, inNote: inNote, text: text, depth: depth, indent: indent) : nil
    }

    /// Whether the brackets still do not balance.
    var isOpen: Bool {
        depth > 0
    }

    /// Joins one trimmed continuation line, with a space between pieces but none after an opening bracket or before a closing one, so the text reads as the one-line spelling.
    ///
    /// An empty `piece` is a blank line Swift Testing printed inside the expression: nothing is joined, and it counts toward the cap like a joined line.
    mutating func join(_ piece: String) {
        guard !piece.isEmpty else {
            lines += 1
            return
        }
        if let last = text.last, let first = piece.first, !"([{".contains(last), !")]}".contains(first) {
            text += " "
        }
        text += piece
        depth += Self.bracketDepth(of: piece)
        lines += 1
    }

    /// How many more brackets — `(`, `[` and `{` against `)`, `]` and `}` — `text` opens than it closes, outside its string literals.
    ///
    /// A literal is read to its closing quote on the same line, an escaped quote inside it included, so `label == "a ("` opens nothing; one left unclosed at the end of the line ends there.
    static func bracketDepth(of text: String) -> Int {
        var depth = 0
        var inLiteral = false
        var escaped = false
        for character in text {
            if inLiteral {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inLiteral = false
                }
                continue
            }
            switch character {
            case "\"": inLiteral = true
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// `text` read as one line: the stream keeps an `#expect` written over several lines with the source's line breaks and indentation, while the console's reading joins them, and both must read alike.
    static func oneLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else {
            return text
        }
        let pieces = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = pieces.first else {
            return ""
        }
        var joined = RunExpressionJoin(index: 0, inNote: false, text: first, depth: 0)
        pieces.dropFirst().forEach { joined.join($0) }
        return joined.text
    }
}
