//
// Copyright © Agulhas Labs
//

/// Reads Swift source one line at a time and hands back the string literals written on each line.
///
/// A lexer rather than a parse: `strings` asks which lines hold a piece of wording, and a line-by-line scan answers that over a whole tree in the time a parse takes over a few files. What it must get right is where a literal starts and stops, so it tracks the three things that move that boundary: a `\"` escape, a `"""` block left open across lines, and a comment — a `//` ends the line's code, and a `/* … */` (nested, as Swift allows) is skipped wherever it falls. Raw delimiters (`#"…"#`) are honoured, so a quote inside one does not close it.
///
/// An interpolation is kept in the literal's text as written, and left out of its segments: the wording is what the segments hold, and the expression inside `\(…)` is code — but a string literal nested in one (recursively, to any depth) is reported as a literal of its own, in single-line, multi-line and raw literals alike.
///
/// Beside the literals it says which ones a `+` joins to the plain literal before it, across lines and comments (``continuesRun``), so wording built as `"the build " +` / `"did not complete"` can be read whole. Only a closed literal with no interpolation joins; any other code between the two, another operator spelled with `+` (`+=`), a `#` directive, a `"""` block or an interpolated literal breaks the join.
struct SwiftLiteralLexer {
    /// How deep inside nested `/* … */` comments the previous line ended.
    private var commentDepth = 0
    /// The number of `#` around a `"""` block the previous line left open, or `nil` outside one.
    private var openBlockHashes: Int?
    /// Where the code since the last literal leaves a `+` join: just past a plain literal, just past the `+` after one, or neither.
    private var join = Join.other
    /// One flag per literal the last line returned, in order: whether `+` joins it to the plain literal before it, so the two print as one piece of wording.
    private(set) var continuesRun: [Bool] = []

    /// Whether the next line begins in code, outside every block comment and multi-line literal the previous lines left open.
    var isInCode: Bool {
        commentDepth == 0 && openBlockHashes == nil
    }

    /// The literals written on `line`, in order, carrying the lexer's state on to the next line.
    mutating func literals(on line: Substring) -> [Literal] {
        let characters = Array(line)
        var found: [Literal] = []
        var joins: [Bool] = []
        defer { continuesRun = joins }
        var index = 0
        if let hashes = openBlockHashes {
            let body = Self.body(of: characters, from: 0, hashes: hashes, isBlock: true)
            let trimmed = body.literal.text.drop { $0 == " " || $0 == "\t" }
            if !trimmed.isEmpty {
                let dropped = body.literal.text.count - trimmed.count
                found.append(Literal(text: String(trimmed), segments: body.literal.segments, printedSegments: body.literal.printedSegments, segmentStarts: body.literal.segmentStarts.map { $0 - dropped }))
            }
            found.append(contentsOf: body.nested)
            joins = Array(repeating: false, count: found.count)
            join = .other
            guard body.closed else {
                return found
            }
            openBlockHashes = nil
            index = body.end
        }
        while index < characters.count {
            if commentDepth > 0 {
                index = skipComment(in: characters, from: index)
                continue
            }
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "/", next == "/" {
                break
            }
            if character == "/", next == "*" {
                commentDepth = 1
                index += 2
                continue
            }
            guard character == "#" || character == "\"" else {
                join = Self.join(after: character, from: join)
                index += 1
                continue
            }
            var quote = index
            while quote < characters.count, characters[quote] == "#" {
                quote += 1
            }
            guard quote < characters.count, characters[quote] == "\"" else {
                join = .other
                index = max(quote, index + 1)
                continue
            }
            let hashes = quote - index
            if Self.isBlockDelimiter(characters, at: quote) {
                // A block's text starts on the next line; nothing may follow its opening delimiter.
                openBlockHashes = hashes
                join = .other
                return found
            }
            let body = Self.body(of: characters, from: quote + 1, hashes: hashes, isBlock: false)
            let isPlain = body.closed && body.literal.segments.count == 1
            found.append(body.literal)
            found.append(contentsOf: body.nested)
            joins.append(isPlain && join == .afterPlus)
            joins += Array(repeating: false, count: body.nested.count)
            join = isPlain ? .afterLiteral : .other
            index = body.end
        }
        return found
    }

    /// Steps through a `/* … */` comment, counting nested openings, and returns where scanning resumes.
    private mutating func skipComment(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, commentDepth > 0 {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if characters[index] == "/", next == "*" {
                commentDepth += 1
                index += 2
            } else if characters[index] == "*", next == "/" {
                commentDepth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }
}

extension SwiftLiteralLexer {
    /// One string literal: its text as written between the delimiters, and the literal segments between its interpolations.
    struct Literal: Equatable {
        let text: String
        let segments: [String]
        /// `segments`, each unescaped to the text it prints — identical to `segments` for a raw string, which has no escapes.
        let printedSegments: [String]
        /// The character offset in `text` where each of `segments` starts; negative for a block line's first segment by the indentation `text` drops.
        let segmentStarts: [Int]

        init(text: String, segments: [String], printedSegments: [String]? = nil, segmentStarts: [Int]) {
            self.text = text
            self.segments = segments
            self.printedSegments = printedSegments ?? segments
            self.segmentStarts = segmentStarts
        }

        /// Whether any literal segment holds `query`, matched with smart case against either its source spelling or its printed text.
        func contains(_ query: String) -> Bool {
            zip(segments, printedSegments).contains { spelling, printed in
                SmartCaseQuery.contains(spelling, query: query) || SmartCaseQuery.contains(printed, query: query)
            }
        }

        /// How `query` matched around this literal's interpolations, read against the text it prints, `nil` when it does not match (``InterpolationWildcard``).
        func match(around query: InterpolationWildcard.Query) -> InterpolationWildcard.Match? {
            InterpolationWildcard.match(of: query, in: printedSegments).map { $0.located(at: writtenRange(of: $0.anchor, inSegment: $0.segment)) }
        }

        /// Where segment `index` of `text` spells `anchor`, text it prints: the whole of it, or else its longest run free of the characters an escape spells differently or the segment lacks; `nil` when the segment spells no run of it.
        private func writtenRange(of anchor: String, inSegment index: Int) -> Range<Int>? {
            let written = segments[index]
            let spelled = Set(written + written.lowercased())
            let runs = anchor.split { $0 == "\"" || $0 == "\\" || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } || !spelled.contains($0) }
            let longestFirst = runs.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }.map(\.element)
            for run in [Substring(anchor)] + longestFirst {
                guard let found = SmartCaseQuery.range(of: String(run), in: written) else { continue }
                let start = segmentStarts[index] + written.distance(from: written.startIndex, to: found.lowerBound)
                let range = start ..< start + written.distance(from: found.lowerBound, to: found.upperBound)
                if range.lowerBound >= 0, range.upperBound <= text.count {
                    return range
                }
            }
            return nil
        }
    }
}

private extension SwiftLiteralLexer {
    /// The code between two literals, read for a `+` joining them.
    enum Join {
        case afterLiteral
        case afterPlus
        case other
    }

    /// The join state once `character`, a character of code outside every literal and comment, is read: whitespace keeps it, a `+` just past a plain literal moves it on, and anything else ends it — so an operator spelled with more than a `+` (`+=`, `++`) ends it on its second character.
    static func join(after character: Character, from state: Join) -> Join {
        if character == " " || character == "\t" || character == "\r" {
            return state
        }
        return character == "+" && state == .afterLiteral ? .afterPlus : .other
    }

    /// A literal's body read from just past its opening delimiter: the literal, where scanning resumes, and whether it closed on this line.
    struct Body {
        let literal: Literal
        let end: Int
        let closed: Bool
        /// Literals nested inside this one's interpolations, in the order they appear.
        let nested: [Literal]
    }

    static func isBlockDelimiter(_ characters: [Character], at index: Int) -> Bool {
        index + 2 < characters.count && characters[index + 1] == "\"" && characters[index + 2] == "\""
    }

    /// Whether `hashes` `#` characters start at `index`.
    static func hasHashes(_ characters: [Character], at index: Int, count hashes: Int) -> Bool {
        index + hashes <= characters.count && characters[index ..< index + hashes].allSatisfy { $0 == "#" }
    }

    /// `segment` unescaped to the text it prints: `\"` → `"`, `\\` → `\`, `\n`/`\t`/`\r`/`\0` → the character, `\u{…}` → the scalar.
    static func printed(_ segment: String) -> String {
        let characters = Array(segment)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            switch characters[index + 1] {
            case "\"":
                result.append("\"")
                index += 2
            case "\\":
                result.append("\\")
                index += 2
            case "n":
                result.append("\n")
                index += 2
            case "t":
                result.append("\t")
                index += 2
            case "r":
                result.append("\r")
                index += 2
            case "0":
                result.append("\0")
                index += 2
            case "u" where index + 2 < characters.count && characters[index + 2] == "{":
                var scan = index + 3
                var hex = ""
                while scan < characters.count, characters[scan] != "}" {
                    hex.append(characters[scan])
                    scan += 1
                }
                if scan < characters.count, let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                    index = scan + 1
                } else {
                    result.append(characters[index])
                    index += 1
                }
            default:
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    static func body(of characters: [Character], from start: Int, hashes: Int, isBlock: Bool) -> Body {
        var text = ""
        var segment = ""
        var segments: [String] = []
        var segmentStarts = [0]
        var nested: [Literal] = []
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\"", !isBlock || isBlockDelimiter(characters, at: index) {
                let afterQuotes = index + (isBlock ? 3 : 1)
                if hasHashes(characters, at: afterQuotes, count: hashes) {
                    segments.append(segment)
                    let printedSegments = hashes == 0 ? segments.map(printed) : segments
                    return Body(
                        literal: Literal(text: text, segments: segments, printedSegments: printedSegments, segmentStarts: segmentStarts),
                        end: afterQuotes + hashes,
                        closed: true,
                        nested: nested
                    )
                }
            }
            if character == "\\", hasHashes(characters, at: index + 1, count: hashes) {
                let escaped = index + 1 + hashes
                if escaped < characters.count, characters[escaped] == "(" {
                    segments.append(segment)
                    segment = ""
                    let interpolation = interpolationEnd(in: characters, from: escaped + 1)
                    nested.append(contentsOf: interpolation.nested)
                    text += String(characters[index ..< interpolation.end])
                    segmentStarts.append(text.count)
                    index = interpolation.end
                } else {
                    let resume = min(escaped + 1, characters.count)
                    text += String(characters[index ..< resume])
                    segment += String(characters[index ..< resume])
                    index = resume
                }
                continue
            }
            text.append(character)
            segment.append(character)
            index += 1
        }
        segments.append(segment)
        let printedSegments = hashes == 0 ? segments.map(printed) : segments
        return Body(literal: Literal(text: text, segments: segments, printedSegments: printedSegments, segmentStarts: segmentStarts), end: characters.count, closed: false, nested: nested)
    }

    /// Where scanning resumes after the `)` closing an interpolation opened just before `start`, and the literals found nested inside it — recursively, since a nested literal can itself hold an interpolation.
    static func interpolationEnd(in characters: [Character], from start: Int) -> (end: Int, nested: [Literal]) {
        var depth = 1
        var index = start
        var nested: [Literal] = []
        while index < characters.count {
            switch characters[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return (index + 1, nested)
                }
            case "\"":
                let inner = body(of: characters, from: index + 1, hashes: 0, isBlock: false)
                nested.append(inner.literal)
                nested.append(contentsOf: inner.nested)
                index = inner.end
                continue
            default:
                break
            }
            index += 1
        }
        return (characters.count, nested)
    }
}
