//
// Copyright © Agulhas Labs
//

import Foundation

/// How one whole-word hit of a name sits in code, read from the bytes on either side with no parse, so what a file writes now can be set against what the store recorded of it at the build (``WhereChangedFileMentions``).
///
/// The store records a declaration of a type, member or function as one and every use of one as a reference, but nothing of a local, a parameter, an argument label or a tuple's element: a file binding the name locally writes it more often than the store ever records, edited or not, so its bare hits are not counted against the store's, only its member accesses, and a file labelling a tuple's element with the name has none of those counted either, since an access to the element reads as one.
struct WrittenNameShape {
    /// Written where a binding the store never records sits: after `let` or `var`, before a single `:` as a label or a parameter, before `in` as a closure's or a loop's, or inside a tuple pattern or a closure's parameter list.
    let isBinding: Bool
    /// Written as a declaration: a binding, or after a keyword that declares a type, member or case.
    let isDeclaration: Bool
    /// Written after a `.`, as a member reached through a value, a type or an implicit one.
    let isMemberAccess: Bool
    /// Written as a tuple's element label, `(file: 1, path: "x")` or `-> (file: Int, path: String)`, in parentheses no callee precedes.
    let isTupleLabel: Bool

    private static let declaringKeywords: Set<String> = ["func", "case", "struct", "class", "enum", "protocol", "actor", "typealias", "associatedtype", "macro"]
    /// The words a tuple's opening parenthesis can follow where no callee does.
    private static let tupleLeadingWords: Set<String> = ["return", "in", "try", "await", "throw", "yield"]
    /// The words a tuple pattern binding its names follows.
    private static let bindingPatternWords: Set<String> = ["for", "let", "var"]

    /// The shape of the hit `length` bytes long at `offset` in `source`.
    init(at offset: Int, length: Int, in source: UnsafeRawBufferPointer) {
        var before = offset - 1
        if before >= 0, source[before] == UInt8(ascii: "`") {
            before -= 1
        }
        before = Self.skippingSpace(backFrom: before, in: source)
        var after = offset + length
        if after < source.count, source[after] == UInt8(ascii: "`") {
            after += 1
        }
        after = Self.skippingSpace(from: after, in: source)
        let previous = before >= 0 ? source[before] : 0
        let previousWord = Self.word(endingAt: before, in: source)
        let labelled = after < source.count && source[after] == UInt8(ascii: ":")
            && (after + 1 == source.count || source[after + 1] != UInt8(ascii: ":"))
            && ![UInt8(ascii: "."), UInt8(ascii: "?"), UInt8(ascii: "[")].contains(previous)
        let boundIn = Self.word(startingAt: after, in: source) == "in"
        let patterned = previous != UInt8(ascii: ".")
            && (Self.isInTuplePattern(from: offset, to: offset + length, in: source) || Self.isInClosureParameters(from: offset, to: offset + length, in: source))
        isMemberAccess = previous == UInt8(ascii: ".")
        isTupleLabel = labelled && Self.isTupleLabel(at: offset, in: source)
        isBinding = previousWord == "let" || previousWord == "var" || labelled || boundIn || patterned
        isDeclaration = isBinding || Self.declaringKeywords.contains(previousWord)
    }

    /// Whether the label starting at `offset` sits in parentheses that open a tuple rather than a call's arguments or a declaration's parameters: no word but a keyword, and no `)`, `]`, `>` other than `->`, `?` or `!`, before the parenthesis.
    private static func isTupleLabel(at offset: Int, in source: UnsafeRawBufferPointer) -> Bool {
        guard let open = enclosingOpenParenthesis(before: offset, in: source, permissive: true) else { return false }
        let before = skippingSpace(backFrom: open - 1, in: source)
        guard before >= 0 else { return true }
        let previous = source[before]
        if isWordByte(previous) {
            return tupleLeadingWords.contains(word(endingAt: before, in: source))
        }
        if previous == UInt8(ascii: ">") {
            return before > 0 && source[before - 1] == UInt8(ascii: "-")
        }
        return ![UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "?"), UInt8(ascii: "!")].contains(previous)
    }

    /// Whether the hit from `start` to `end` is an element of a tuple pattern, nested or not, or of an enum case's, that `for`, `let` or `var` opens or `in` closes: `for (path, n) in`, `let (path, n) =`, `case let .file(path):`, `{ (path, n) in`.
    private static func isInTuplePattern(from start: Int, to end: Int, in source: UnsafeRawBufferPointer) -> Bool {
        var inner = (start: start, end: end)
        for _ in 0 ..< 4 {
            guard let open = enclosingOpenParenthesis(before: inner.start, in: source, permissive: false),
                  let close = enclosingCloseParenthesis(after: inner.end, in: source) else { return false }
            let before = skippingSpace(backFrom: open - 1, in: source)
            if bindingPatternWords.contains(word(endingAt: skippingCaseName(backFrom: before, in: source), in: source))
                || word(startingAt: skippingSpace(from: close + 1, in: source), in: source) == "in"
            {
                return true
            }
            guard before >= 0, [UInt8(ascii: ","), UInt8(ascii: "(")].contains(source[before]) else { return false }
            inner = (open, close + 1)
        }
        return false
    }

    /// Whether the hit from `start` to `end` is one of a closure's parameters written on its line with no parentheses, `{ path, n in`: only names and commas between the `{` and the `in`.
    private static func isInClosureParameters(from start: Int, to end: Int, in source: UnsafeRawBufferPointer) -> Bool {
        var back = start - 1
        while back >= 0, isWordByte(source[back]) || isInlineSpace(source[back]) || source[back] == UInt8(ascii: ",") {
            back -= 1
        }
        guard back >= 0, source[back] == UInt8(ascii: "{") else { return false }
        var ahead = end
        while ahead < source.count {
            if isInlineSpace(source[ahead]) || source[ahead] == UInt8(ascii: ",") {
                ahead += 1
                continue
            }
            let following = word(startingAt: ahead, in: source)
            if following == "in" {
                return true
            }
            guard !following.isEmpty else { return false }
            ahead += following.utf8.count
        }
        return false
    }

    /// The offset of the `(` left open before `offset`, scanning back over balanced brackets: over the bytes a pattern is written with alone, names, commas, colons and spaces, unless `permissive`, which crosses any byte but an unmatched `[` or `{`; `nil` where none is found within a few kilobytes.
    private static func enclosingOpenParenthesis(before offset: Int, in source: UnsafeRawBufferPointer, permissive: Bool) -> Int? {
        var depth = 0
        var index = offset - 1
        while index >= max(0, offset - 4096) {
            let byte = source[index]
            switch byte {
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                guard permissive || byte == UInt8(ascii: ")") else { return nil }
                depth += 1
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
                if depth == 0 {
                    return byte == UInt8(ascii: "(") ? index : nil
                }
                depth -= 1
            default:
                guard permissive || isPatternByte(byte) else { return nil }
            }
            index -= 1
        }
        return nil
    }

    /// The offset of the `)` closing the parentheses open at `offset`, scanning ahead over the bytes a pattern is written with alone; `nil` where another byte comes first.
    private static func enclosingCloseParenthesis(after offset: Int, in source: UnsafeRawBufferPointer) -> Int? {
        var depth = 0
        var index = offset
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "(") {
                depth += 1
            } else if byte == UInt8(ascii: ")") {
                if depth == 0 {
                    return index
                }
                depth -= 1
            } else if !isPatternByte(byte) {
                return nil
            }
            index += 1
        }
        return nil
    }

    /// The offset before the enum case name, `.file` or `Kind.file`, whose last byte is at `end`, spaces skipped, so the `let` of `case let .file(path)` is the word there; `end` itself where no `.` precedes the name.
    private static func skippingCaseName(backFrom end: Int, in source: UnsafeRawBufferPointer) -> Int {
        var index = end
        while index >= 0, isWordByte(source[index]) {
            index -= 1
        }
        guard index >= 0, index < end, source[index] == UInt8(ascii: ".") else { return end }
        while index >= 0, source[index] == UInt8(ascii: ".") || isWordByte(source[index]) {
            index -= 1
        }
        return skippingSpace(backFrom: index, in: source)
    }

    private static func isPatternByte(_ byte: UInt8) -> Bool {
        isWordByte(byte) || isSpace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: ":")
    }

    private static func skippingSpace(backFrom offset: Int, in source: UnsafeRawBufferPointer) -> Int {
        var index = offset
        while index >= 0, isSpace(source[index]) {
            index -= 1
        }
        return index
    }

    private static func skippingSpace(from offset: Int, in source: UnsafeRawBufferPointer) -> Int {
        var index = offset
        while index < source.count, isSpace(source[index]) {
            index += 1
        }
        return index
    }

    private static func isInlineSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        isInlineSpace(byte) || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
    }

    /// The ASCII word whose last byte is at `end`, empty where none is.
    private static func word(endingAt end: Int, in source: UnsafeRawBufferPointer) -> String {
        var start = end
        while start >= 0, isWordByte(source[start]) {
            start -= 1
        }
        return start == end ? "" : String(bytes: source[(start + 1) ... end], encoding: .utf8) ?? ""
    }

    /// The ASCII word whose first byte is at `start`, empty where none is.
    private static func word(startingAt start: Int, in source: UnsafeRawBufferPointer) -> String {
        var end = start
        while end < source.count, isWordByte(source[end]) {
            end += 1
        }
        return String(bytes: source[start ..< end], encoding: .utf8) ?? ""
    }
}
