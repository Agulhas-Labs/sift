//
// Copyright © Agulhas Labs
//

/// One pass over a file's bytes measuring the nestings the parser's cap does not bound, that stops at the first past its limit in ``NestingGate``.
///
/// A run is the `[`s a type lookahead descends through without stopping: `[` after `[`, with nothing between them but whitespace, `(` and a generic type's `Name<` (the name written directly against its `<`). Any other token ends it, so an array of ranges, a shift, a comparison or a `..<` never adds to one. The generic depth is the count of `Name<` not yet closed by a `>` (an arrow's aside), started afresh at every `{`, `}` and `;`, none of which a generic argument holds: a comparison written without spaces adds to it until the next of them, as it adds to the parser's lookahead for generic arguments, but a shift or a `<=` (`Name<<`, `Name<=`) does not.
///
/// The chains are the steps the parser takes one recursion each: prefix keywords in a row (`try`, `try?`, `await` and the rest of ``prefixKeywords``), function arrows since the last declaration keyword, `{`, `}` or `;`, and the `else if` arms in each block (each block keeps its own count, so a chain whose arms hold chains of their own is still counted whole). The condition depth is the count of `#if` not yet closed by an `#endif`.
///
/// Comments (block comments nest), string text and regex literals (`#/…/#`, and a bare `/…/` where it cannot be a division) are skipped; an interpolation's code is read as code, and the string resumes at its matching `)`.
struct NestingScan {
    /// The strings an open interpolation returns to, each with the parenthesis depth its `\(` opened at.
    private var strings: [(frame: StringFrame, depth: Int)] = []
    private var parentheses = 0
    private var chain = 0
    private var generics = 0
    /// Prefix keywords read in a row.
    private var prefixes = 0
    /// Function arrows read since the last declaration keyword, `{`, `}` or `;`.
    private var arrows = 0
    /// The `else if` arms read in each open block, the innermost last.
    private var elseIfs = [0]
    /// The `#if`s not yet closed by an `#endif`.
    private var conditions = 0
    /// The last byte of code read, whitespace and comments aside: what tells a regex literal's `/` from a division's.
    private var previous = UInt8(ascii: "\n")
    /// The word read last, where the last token read was a word: what tells an `else if` arm, and a regex literal after a keyword.
    private var previousWord: String?

    /// Whether `bytes` hold no run past the limit.
    mutating func run(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        var inString: StringFrame?
        while index < bytes.count {
            if let frame = inString {
                guard let next = skipString(frame, in: bytes, from: index) else { return true }
                if next.interpolates {
                    strings.append((frame, parentheses))
                    parentheses += 1
                    previous = UInt8(ascii: "(")
                } else {
                    previous = UInt8(ascii: "\"")
                }
                inString = nil
                index = next.index
                continue
            }
            let byte = bytes[index]
            if Self.isWhitespace(byte) {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                index = lineEnd(in: bytes, from: index)
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index = skipBlockComment(in: bytes, from: index)
                continue
            }
            if let end = regexEnd(in: bytes, at: index) {
                chain = 0
                prefixes = 0
                previousWord = nil
                previous = UInt8(ascii: "/")
                index = end
                continue
            }
            if !Self.isIdentifierStart(byte) {
                prefixes = 0
                previousWord = nil
            }
            if byte == UInt8(ascii: "#") || byte == UInt8(ascii: "\""), let opened = openString(in: bytes, at: index) {
                chain = 0
                inString = opened.frame
                index = opened.index
                continue
            }
            if Self.isIdentifierStart(byte) {
                let end = identifierEnd(in: bytes, from: index)
                if end < bytes.count, bytes[end] == UInt8(ascii: "<"), end + 1 == bytes.count || !"<=".utf8.contains(bytes[end + 1]) {
                    generics += 1
                    guard generics <= NestingGate.maximumGenericDepth else { return false }
                    prefixes = 0
                    previousWord = nil
                    previous = UInt8(ascii: "<")
                    index = end + 1
                } else {
                    chain = 0
                    let word = Self.word(in: bytes, from: index, to: end)
                    guard read(word, directive: index > 0 && bytes[index - 1] == UInt8(ascii: "#")) else { return false }
                    previous = bytes[end - 1]
                    index = end
                    if word == "try", end < bytes.count, "?!".utf8.contains(bytes[end]) {
                        previous = bytes[end]
                        index = end + 1
                    }
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "["):
                chain += 1
                guard chain <= NestingGate.maximumTypeChain else { return false }
            case UInt8(ascii: "("):
                parentheses += 1
            case UInt8(ascii: ")"):
                chain = 0
                if let top = strings.last, top.depth == parentheses - 1 {
                    strings.removeLast()
                    inString = top.frame
                }
                parentheses = max(0, parentheses - 1)
            case UInt8(ascii: ">"):
                chain = 0
                if previous != UInt8(ascii: "-") {
                    generics = max(0, generics - 1)
                } else {
                    arrows += 1
                    guard arrows <= NestingGate.maximumChain else { return false }
                }
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ";"):
                chain = 0
                generics = 0
                arrows = 0
                if byte == UInt8(ascii: "{") {
                    elseIfs.append(0)
                } else if byte == UInt8(ascii: "}"), elseIfs.count > 1 {
                    elseIfs.removeLast()
                }
            default:
                chain = 0
            }
            previous = byte
            index += 1
        }
        return true
    }

    /// Counts `word` into the chain it continues, and whether every chain stays within its limit; `directive` where it is a compiler directive's (`#if`).
    private mutating func read(_ word: String, directive: Bool) -> Bool {
        defer { previousWord = directive ? nil : word }
        if directive {
            if word == "if" {
                conditions += 1
                return conditions <= NestingGate.maximumConditionDepth
            }
            if word == "endif" {
                conditions = max(0, conditions - 1)
            }
            return true
        }
        prefixes = Self.prefixKeywords.contains(word) ? prefixes + 1 : 0
        if Self.declarationKeywords.contains(word) {
            arrows = 0
        }
        if word == "if", previousWord == "else" {
            elseIfs[elseIfs.count - 1] += 1
        }
        return prefixes <= NestingGate.maximumChain && elseIfs[elseIfs.count - 1] <= NestingGate.maximumChain
    }

    /// The name from `start` to `end`, or an empty one where it is longer than any keyword.
    private static func word(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String {
        let length = end - start
        guard length <= 16 else { return "" }
        return String(unsafeUninitializedCapacity: length) { buffer in
            for offset in 0 ..< length {
                buffer[offset] = bytes[start + offset]
            }
            return length
        }
    }

    /// The keywords the parser reads as a prefix of the expression or type that follows, descending once for each.
    private static let prefixKeywords: Set<String> = [
        "try", "await", "unsafe", "consume", "copy", "any", "some", "each", "repeat", "borrowing", "consuming", "inout", "sending", "isolated",
        "_move", "_borrow", "__owned", "__shared",
    ]

    /// The keywords that open a declaration, which no function type holds: where a chain of arrows starts afresh.
    private static let declarationKeywords: Set<String> = ["func", "var", "let", "subscript", "init", "case", "typealias", "associatedtype", "macro"]

    /// The keywords after which a `/` cannot be a division.
    private static let precedesBareRegexWords: Set<String> = ["return", "throw", "in", "case", "try", "await", "if", "guard", "while", "where", "switch", "repeat", "else"]

    /// The index just past a regex literal opening at `start`, or `nil` where none does.
    ///
    /// An extended one (`#/…/#`, any number of `#`s) runs to its matching close, over lines. A bare `/…/` is taken as one only where a division cannot stand, after an opening bracket, a comma, a colon, an operator or a keyword such as `return`, and only where it starts with no space and closes on its line; anything else is left to be read as the operator it is.
    private func regexEnd(in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        let hashes = hashes(in: bytes, from: start)
        guard start + hashes < bytes.count, bytes[start + hashes] == UInt8(ascii: "/") else { return nil }
        var index = start + hashes + 1
        if hashes > 0 {
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "/"), self.hashes(in: bytes, from: index + 1) >= hashes {
                    return index + 1 + hashes
                }
                index += 1
            }
            return bytes.count
        }
        guard Self.precedesBareRegex.contains(previous) || previousWord.map(Self.precedesBareRegexWords.contains) == true, index < bytes.count, !Self.isWhitespace(bytes[index]) else { return nil }
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            if bytes[index] == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if bytes[index] == UInt8(ascii: "/") {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    /// The bytes after which a `/` cannot be a division: the start of the file, an opening bracket, a separator, an assignment or another operator.
    private static let precedesBareRegex: Set<UInt8> = Set("\n([{,:;=!&|?^~+-*%<>".utf8)

    /// The string that opens at `start` (`#`s, then one or three `"`), and the index just past its opening delimiter; `nil` where no string opens there.
    private func openString(in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> (frame: StringFrame, index: Int)? {
        let hashes = hashes(in: bytes, from: start)
        let index = start + hashes
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        let multiline = index + 2 < bytes.count && bytes[index + 1] == UInt8(ascii: "\"") && bytes[index + 2] == UInt8(ascii: "\"")
        return (StringFrame(hashes: hashes, multiline: multiline), index + (multiline ? 3 : 1))
    }

    /// Reads string text from `start` to its close or its next interpolation, and the index just past it; `nil` where the file ends first.
    private func skipString(_ frame: StringFrame, in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> (index: Int, interpolates: Bool)? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), hashes(in: bytes, from: index + 1) >= frame.hashes {
                let after = index + 1 + frame.hashes
                guard after < bytes.count else { return nil }
                if bytes[after] == UInt8(ascii: "(") {
                    return (after + 1, true)
                }
                index = frame.hashes == 0 ? after + 1 : after
                continue
            }
            if byte == UInt8(ascii: "\""), closes(frame, in: bytes, at: index) {
                return (index + (frame.multiline ? 3 : 1) + frame.hashes, false)
            }
            if byte == UInt8(ascii: "\n"), !frame.multiline {
                return (index, false)
            }
            index += 1
        }
        return nil
    }

    /// Whether the `"` at `index` closes `frame`: three of them for a multi-line string, then as many `#`s as opened it.
    private func closes(_ frame: StringFrame, in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        let quotes = frame.multiline ? 3 : 1
        guard index + quotes <= bytes.count, (index ..< index + quotes).allSatisfy({ bytes[$0] == UInt8(ascii: "\"") }) else { return false }
        return hashes(in: bytes, from: index + quotes) >= frame.hashes
    }

    /// How many `#`s run from `start`.
    private func hashes(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] == UInt8(ascii: "#") {
            index += 1
        }
        return index - start
    }

    /// The index of the newline ending the line `start` is on, or the end of the file.
    private func lineEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") {
            index += 1
        }
        return index
    }

    /// The index just past the name starting at `start`: identifier characters, with a `.` joining two names.
    private func identifierEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            if Self.isIdentifierStart(bytes[index]) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            } else if bytes[index] == UInt8(ascii: "."), index + 1 < bytes.count, Self.isIdentifierStart(bytes[index + 1]) {
                index += 2
            } else {
                break
            }
        }
        return index
    }

    /// The index just past the block comment opening at `start`, nested comments included, or the end of the file where it never closes.
    private func skipBlockComment(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start + 2
        var open = 1
        while index < bytes.count, open > 0 {
            if bytes[index] == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                open += 1
                index += 2
            } else if bytes[index] == UInt8(ascii: "*"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                open -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    /// A byte that can start a name: a letter, `_`, `$`, or any byte of a multi-byte character.
    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte >= 0x80
    }
}

extension NestingScan {
    /// A string being read: the number of `#`s it is delimited by, and whether it is a multi-line one.
    struct StringFrame {
        let hashes: Int
        let multiline: Bool
    }
}
