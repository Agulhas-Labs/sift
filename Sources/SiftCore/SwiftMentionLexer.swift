//
// Copyright © Agulhas Labs
//

import Foundation

/// Where one Swift file's bytes write a name as a whole word, each hit placed in code, a string literal, a comment or a doc comment, for ``WhereUnbuiltMentions`` and ``NonCodeMentions``.
///
/// A byte search finds the name first, so a file that never writes it costs its read and that search, never a decode. Only a file with a hit is lexed, once, by a small state machine over its bytes that knows `//` and nested `/* */` comments, `///` and `/** */` doc comments, string literals (`"…"`, `"""…"""`, raw `#"…"#` with any number of `#`, `\` escapes) and the code inside their interpolations, and it stops at the last hit.
struct SwiftMentionLexer {
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let quote = UInt8(ascii: "\"")
    private static let hash = UInt8(ascii: "#")
    private static let backslash = UInt8(ascii: "\\")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let newline = UInt8(ascii: "\n")

    private let bytes: UnsafeRawBufferPointer
    private let hits: [Int]
    private var index = 0
    private var line = 1
    private var nextHit = 0
    private var frames: [Frame] = []
    private var found: [Hit] = []
    private var unbounded = 0

    /// Every place `source` writes one of `names` as a whole word, in byte order, each with its line and what it is written in.
    static func hits(writing names: [[UInt8]], in source: UnsafeRawBufferPointer) -> [Hit] {
        let hits = wordHits(of: names, in: source)
        guard !hits.isEmpty else { return [] }
        var lexer = SwiftMentionLexer(bytes: source, hits: hits)
        return lexer.run()
    }

    /// The offsets in `source` where one of `names` starts with no identifier character against either end, ascending.
    static func wordHits(of names: [[UInt8]], in source: UnsafeRawBufferPointer) -> [Int] {
        guard let base = source.baseAddress else { return [] }
        var hits: [Int] = []
        for name in names where !name.isEmpty {
            name.withUnsafeBytes { needle in
                var start = 0
                while start < source.count, let match = memmem(base + start, source.count - start, needle.baseAddress, needle.count) {
                    let offset = base.distance(to: UnsafeRawPointer(match))
                    if !isIdentifier(endingAt: offset, in: source), !isIdentifier(startingAt: offset + needle.count, in: source) {
                        hits.append(offset)
                    }
                    start = offset + 1
                }
            }
        }
        return hits.sorted()
    }

    /// Whether the character starting at `offset` continues an identifier: an ASCII letter, digit or `_`, or a Unicode letter or number.
    private static func isIdentifier(startingAt offset: Int, in source: UnsafeRawBufferPointer) -> Bool {
        guard offset < source.count else { return false }
        let byte = source[offset]
        guard byte >= 0x80 else { return isIdentifierASCII(byte) }
        return isIdentifierScalar(in: UnsafeRawBufferPointer(rebasing: source[offset ..< min(offset + 4, source.count)]))
    }

    /// Whether the character ending just before `offset` continues an identifier, its UTF-8 lead byte found by stepping back over continuation bytes.
    private static func isIdentifier(endingAt offset: Int, in source: UnsafeRawBufferPointer) -> Bool {
        guard offset > 0 else { return false }
        let byte = source[offset - 1]
        guard byte >= 0x80 else { return isIdentifierASCII(byte) }
        var lead = offset - 1
        while lead > max(0, offset - 4), source[lead] & 0xC0 == 0x80 {
            lead -= 1
        }
        return isIdentifierScalar(in: UnsafeRawBufferPointer(rebasing: source[lead ..< offset]))
    }

    private static func isIdentifierASCII(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    private static func isIdentifierScalar(in bytes: UnsafeRawBufferPointer) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        guard case let .scalarValue(scalar) = decoder.decode(&iterator) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private mutating func run() -> [Hit] {
        while index < bytes.count, nextHit < hits.count || unbounded > 0 {
            while nextHit < hits.count, hits[nextHit] < index {
                nextHit += 1
            }
            if case .string? = frames.last {
                record(.string)
            } else {
                record(.code)
            }
            if case let .string(hashes, multiline, _)? = frames.last {
                stepInString(hashes: hashes, multiline: multiline)
            } else {
                stepInCode()
            }
        }
        if unbounded > 0 {
            let starts = Set(found.compactMap { $0.place == .string && $0.content?.isEmpty == true ? $0.content?.lowerBound : nil })
            for start in starts {
                closeStrings(from: start, at: bytes.count)
            }
        }
        return found
    }

    /// Records the hit at the current byte, if one starts there, as written in `place`.
    private mutating func record(_ place: Place) {
        guard nextHit < hits.count, hits[nextHit] == index else { return }
        var content: Range<Int>?
        if place == .string, case let .string(_, _, start)? = frames.last {
            content = start ..< start
            unbounded += 1
        }
        found.append(Hit(offset: index, line: line, place: place, content: content))
        nextHit += 1
    }

    private func byte(at offset: Int) -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private func hashes(_ count: Int, at offset: Int) -> Bool {
        offset + count <= bytes.count && (0 ..< count).allSatisfy { bytes[offset + $0] == Self.hash }
    }

    private mutating func stepInCode() {
        switch bytes[index] {
        case Self.slash where byte(at: index + 1) == Self.slash:
            let place: Place = byte(at: index + 2) == Self.slash && byte(at: index + 3) != Self.slash ? .doc : .comment
            while index < bytes.count, bytes[index] != Self.newline {
                record(place)
                index += 1
            }
        case Self.slash where byte(at: index + 1) == Self.star:
            skipBlockComment(as: byte(at: index + 2) == Self.star && byte(at: index + 3) != Self.slash ? .doc : .comment)
        case Self.quote, Self.hash:
            openString()
        case Self.openParen:
            if case let .interpolation(parens)? = frames.last {
                frames[frames.count - 1] = .interpolation(parens: parens + 1)
            }
            index += 1
        case Self.closeParen:
            if case let .interpolation(parens)? = frames.last {
                if parens == 0 {
                    frames.removeLast()
                } else {
                    frames[frames.count - 1] = .interpolation(parens: parens - 1)
                }
            }
            index += 1
        case Self.newline:
            line += 1
            index += 1
        default:
            index += 1
        }
    }

    private mutating func skipBlockComment(as place: Place) {
        var depth = 0
        while index < bytes.count {
            record(place)
            if bytes[index] == Self.slash, byte(at: index + 1) == Self.star {
                depth += 1
                index += 2
            } else if bytes[index] == Self.star, byte(at: index + 1) == Self.slash {
                depth -= 1
                index += 2
                if depth == 0 {
                    return
                }
            } else {
                if bytes[index] == Self.newline {
                    line += 1
                }
                index += 1
            }
        }
    }

    /// At a `"` or a run of `#`: opens the string literal they start, or steps over `#`s that start none (`#if`, `#expect`).
    private mutating func openString() {
        var count = 0
        while byte(at: index + count) == Self.hash {
            count += 1
        }
        guard byte(at: index + count) == Self.quote else {
            index += count
            return
        }
        let multiline = byte(at: index + count + 1) == Self.quote && byte(at: index + count + 2) == Self.quote
        index += count + (multiline ? 3 : 1)
        frames.append(.string(hashes: count, multiline: multiline, contentStart: index))
    }

    private mutating func stepInString(hashes: Int, multiline: Bool) {
        switch bytes[index] {
        case Self.backslash where self.hashes(hashes, at: index + 1):
            let after = index + 1 + hashes
            if byte(at: after) == Self.openParen {
                frames.append(.interpolation(parens: 0))
                index = after + 1
            } else {
                index = after
                if let escaped = byte(at: index), escaped != Self.newline {
                    index += 1
                }
            }
        case Self.quote where closesString(hashes: hashes, multiline: multiline):
            closeFrame(at: index)
            index += (multiline ? 3 : 1) + hashes
        case Self.newline:
            // A single-line literal cannot hold a newline: dropping it there keeps one malformed literal from turning the rest of the file into string.
            if !multiline {
                closeFrame(at: index)
            }
            line += 1
            index += 1
        default:
            index += 1
        }
    }

    /// Pops the string frame on top and ends the content of its hits at `end`.
    private mutating func closeFrame(at end: Int) {
        guard case let .string(_, _, start)? = frames.popLast() else { return }
        closeStrings(from: start, at: end)
    }

    /// Ends at `end` the content of the string hits whose literal's content starts at `start`.
    private mutating func closeStrings(from start: Int, at end: Int) {
        var position = found.count - 1
        while position >= 0, found[position].offset >= start {
            if found[position].place == .string, found[position].content == start ..< start {
                found[position].content = start ..< end
                unbounded -= 1
            }
            position -= 1
        }
    }

    private func closesString(hashes: Int, multiline: Bool) -> Bool {
        guard multiline else { return self.hashes(hashes, at: index + 1) }
        return byte(at: index + 1) == Self.quote && byte(at: index + 2) == Self.quote && self.hashes(hashes, at: index + 3)
    }
}

extension SwiftMentionLexer {
    /// What a hit is written in: code (an interpolation's included), a string literal, a `//` or `/* */` comment, or a `///` or `/** */` doc comment.
    enum Place: Equatable {
        case code
        case string
        case comment
        case doc
    }

    /// One place the name is written: the byte it starts at, its 1-based line, and what it is written in.
    ///
    /// A hit in a string literal also carries the byte range of the literal's content, delimiters excluded.
    struct Hit: Equatable {
        let offset: Int
        let line: Int
        let place: Place
        var content: Range<Int>?
    }

    /// What the lexer is inside, beneath top-level code: a string literal, or the code of an interpolation in one with its open parentheses counted.
    private enum Frame {
        case string(hashes: Int, multiline: Bool, contentStart: Int)
        case interpolation(parens: Int)
    }
}
