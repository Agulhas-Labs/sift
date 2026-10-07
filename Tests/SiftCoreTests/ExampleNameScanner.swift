//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads a tracked file for the names it *says*, and — in Swift source — separates those from the names it *declares*.
///
/// The distinction is the whole of the permit list's design. A name this repository declares is code: the compiler governs it, a rename is a compile error, and a permit list that had to carry every one of them would fire on an ordinary morning's work. A name standing in a fixture, a string literal, a doc comment or a document is content, governed by nobody, and is exactly where a privacy leak comes to rest — a masked product, a reproduced type, a target layout belonging to somebody else. So the scan divides a `.swift` file in two and reads only half of it.
///
/// It works in UTF-8 bytes rather than characters, and the two halves it returns are the same length as the source with everything not kept blanked to a space and every newline surviving in both. An offset in either half is therefore an offset in the source, and a line number is a count of the newlines before it — which is what lets a finding name `file:line` without a second pass.
struct ExampleNameScanner {
    fileprivate static let space = UInt8(ascii: " ")
    fileprivate static let newline = UInt8(ascii: "\n")
    private static let hash = UInt8(ascii: "#")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let backtick = UInt8(ascii: "`")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")

    // MARK: - Compound identifiers

    /// Whether a token is a compound identifier: four bytes or more, opening with a letter, carrying an uppercase letter somewhere after the first byte and a lowercase letter somewhere at all.
    ///
    /// The first two conditions are the shape of a camel-cased name — `HealthKit`, `XCTAssertEqual`, `aTestThatFailed`. Requiring a lowercase letter is the third, and it is what keeps this from reading English. Without it a token is compound whenever it holds two uppercase letters, so `BASIS`, `MERCHANTABILITY` and `WITHOUT` from a licence, every SQL keyword in a schema, and the hexadecimal object identifiers in an Xcode project file all qualify, and none of them is a name anybody chose. A shouted word has no compound structure to read, and the generic-term list beside this one is the check that covers prose.
    static func isCompound(_ token: ArraySlice<UInt8>) -> Bool {
        guard token.count >= 4, let first = token.first, isLetter(first) else { return false }
        var uppercaseAfterTheFirst = false
        var lowercaseAnywhere = false
        for (offset, byte) in token.enumerated() {
            if offset > 0, isUppercase(byte) {
                uppercaseAfterTheFirst = true
            }
            if isLowercase(byte) {
                lowercaseAnywhere = true
            }
        }

        return uppercaseAfterTheFirst && lowercaseAnywhere
    }

    /// Every compound identifier in the bytes, in the order they were read, each with its line.
    ///
    /// A token starts at a letter and runs to the end of the alphanumerics, so `_` and every byte above ASCII end one. Digits before a letter are skipped rather than joined to it, which is why `x86_64Widget` is read as `Widget`.
    static func sightings(in bytes: [UInt8]) -> [Sighting] {
        var found: [Sighting] = []
        var line = 1
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if bytes[index] == newline {
                line += 1
                index += 1
                continue
            }
            guard isLetter(bytes[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < bytes.endIndex, isAlphanumeric(bytes[end]) {
                end += 1
            }
            if isCompound(bytes[index ..< end]) {
                found.append(Sighting(name: text(of: bytes[index ..< end]), line: line))
            }
            index = end
        }

        return found
    }

    /// The names one file says that neither the permit list nor this repository's own code accounts for — the finding, for one file.
    ///
    /// Both sets are passed in rather than read here, which is what lets the property be exercised against a text of three lines and two names instead of against the tree. A gate whose verdict can only be reproduced by running it over the whole repository is a gate whose verdict nobody can check.
    static func unpermittedNames(
        in bytes: [UInt8],
        isSwift: Bool,
        permitted: Set<String>,
        declared: Set<String>
    ) -> [Sighting] {
        let example = isSwift ? split(swift: bytes).example : bytes

        return sightings(in: example).filter { !permitted.contains($0.name) && !declared.contains($0.name) }
    }

    // MARK: - JSON

    /// The bytes of a JSON document with every escape sequence in its strings blanked to spaces.
    ///
    /// A JSON string spells a newline `\n` and a tab `\t`, and the scan reads the letter after the backslash as the head of the next word, so `"\nBuilding"` is read as a name `nBuilding` that nothing wrote. The backslash and the byte it escapes are blanked, and for `\u` the four hex digits with them, so a unicode escape is not read as a name either. Same length as the source, newlines kept, like the halves a Swift file splits into. A name written out beside an escape is still read.
    static func blankingJSONEscapes(in bytes: [UInt8]) -> [UInt8] {
        var blanked = bytes
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == backslash else {
                index += 1
                continue
            }
            var end = min(index + 2, bytes.endIndex)
            if end - 1 > index, bytes[index + 1] == UInt8(ascii: "u") {
                var digits = 0
                while end < bytes.endIndex, digits < 4, isHexDigit(bytes[end]) {
                    end += 1
                    digits += 1
                }
            }
            for blank in index ..< end where blanked[blank] != newline {
                blanked[blank] = space
            }
            index = end
        }

        return blanked
    }

    /// The bytes of a document that is not Swift, as the scan reads them: a JSON document with its string escapes blanked, anything else as it stands.
    static func exampleText(ofDocument bytes: [UInt8], path: String) -> [UInt8] {
        path.hasSuffix(".json") || path.hasSuffix(".jsonl") ? blankingJSONEscapes(in: bytes) : bytes
    }

    // MARK: - Declarations

    /// The keywords a declared name follows.
    ///
    /// Over-reading is the safe direction and this reads generously: `case` in a switch and `let` in an `if let` both put a name here that nothing declared. Every one of them is a name already standing in this repository's own code, which is the category the permit list deliberately does not govern.
    static let declarationKeywords: Set<String> = [
        "actor", "case", "class", "enum", "func", "let", "protocol", "struct", "typealias", "var",
    ]

    /// The names the code half of a Swift file declares.
    ///
    /// Read from the code half and never from the whole file, which is the property that closes the obvious hole: a fixture that holds a `struct` declaration inside a string literal would otherwise be declaring its own permission.
    static func declaredNames(inCode code: [UInt8]) -> Set<String> {
        var declared: Set<String> = []
        var theNextTokenIsAName = false
        var index = code.startIndex
        while index < code.endIndex {
            guard isIdentifierByte(code[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < code.endIndex, isIdentifierByte(code[end]) {
                end += 1
            }
            let token = text(of: code[index ..< end])
            if theNextTokenIsAName {
                declared.insert(token)
                theNextTokenIsAName = false
            }
            if declarationKeywords.contains(token) {
                theNextTokenIsAName = true
            }
            index = end
        }

        return declared
    }

    /// The compound identifiers the code half of a Swift file mentions, declared here or not.
    ///
    /// A name standing in code is governed by the compiler whoever declared it: it is this repository's own, or it is a framework's, and a framework's type named in a comment is a reference to it rather than an invented example. Read from the code half only, so a name inside a string literal never grants itself a permit, and applied by the gate to comments alone.
    ///
    /// Only a capitalised token counts, and not where it is an argument label or a parameter name: that is a word the code chose for a call site, which no framework declares and no compiler holds a comment to. A token opening a list item (after `(` or `,`) and followed by a colon, or by one more word and then a colon, is such a label; everything else capitalised stands in a type position or is a type expression (`Name(`, `Name.`).
    static func referencedNames(inCode code: [UInt8]) -> Set<String> {
        var names: Set<String> = []
        var index = code.startIndex
        while index < code.endIndex {
            guard isLetter(code[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < code.endIndex, isAlphanumeric(code[end]) {
                end += 1
            }
            defer { index = end }
            guard isUppercase(code[index]), isCompound(code[index ..< end]) else { continue }
            if opensAListItem(before: index, in: code), isLabelOrParameterName(from: end, in: code) {
                continue
            }
            names.insert(text(of: code[index ..< end]))
        }

        return names
    }

    /// Whether the first byte before `index` that is not whitespace is a `(` or a `,`.
    private static func opensAListItem(before index: Int, in code: [UInt8]) -> Bool {
        var cursor = index
        while cursor > code.startIndex {
            cursor -= 1
            if isBlank(code[cursor]) {
                continue
            }

            return code[cursor] == openParen || code[cursor] == comma
        }

        return false
    }

    /// Whether what follows a token ending at `end` is a colon, or one more word and then a colon: the shapes a call's label and a declaration's `label name:` take.
    private static func isLabelOrParameterName(from end: Int, in code: [UInt8]) -> Bool {
        var cursor = end
        func skipBlanks() {
            while cursor < code.endIndex, isBlank(code[cursor]) {
                cursor += 1
            }
        }
        skipBlanks()
        guard cursor < code.endIndex else { return false }
        if code[cursor] == colon {
            return true
        }
        guard isIdentifierByte(code[cursor]) else { return false }
        while cursor < code.endIndex, isIdentifierByte(code[cursor]) {
            cursor += 1
        }
        skipBlanks()

        return cursor < code.endIndex && code[cursor] == colon
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == space || byte == newline || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    // MARK: - Splitting Swift source

    /// Splits Swift source into what it declares and what it says.
    ///
    /// Raw string delimiters are honoured, so `#"a \n b"#` carries no escape and `##"…"##` is closed only by `"##`. An escape and the byte it escapes are both blanked, because `"\nBuilding"` is otherwise read as a name `nBuilding` that nothing wrote.
    static func split(swift source: [UInt8]) -> Split {
        var code = [UInt8](repeating: space, count: source.count)
        var example = code
        var comment = code
        for index in source.indices where source[index] == newline {
            code[index] = newline
            example[index] = newline
            comment[index] = newline
        }

        func keep(_ range: Range<Int>, asExample: Bool) {
            for index in range where source[index] != newline {
                if asExample {
                    example[index] = source[index]
                } else {
                    code[index] = source[index]
                }
            }
        }

        /// A comment is example text like a string literal is, and is also kept apart from the literals in a half of its own.
        func keepComment(_ range: Range<Int>) {
            keep(range, asExample: true)
            for index in range where source[index] != newline {
                comment[index] = source[index]
            }
        }

        func matches(_ literal: [UInt8], at index: Int) -> Bool {
            index + literal.count <= source.count && source[index ..< index + literal.count].elementsEqual(literal)
        }

        func hashes(_ count: Int, at index: Int) -> Bool {
            index + count <= source.count && !source[index ..< index + count].contains { $0 != hash }
        }

        /// The opening delimiter of a string literal at `index`, if one starts there: `"`, `"""`, and either behind any number of `#`.
        func stringOpening(at index: Int) -> Opening? {
            var afterHashes = index
            while afterHashes < source.count, source[afterHashes] == hash {
                afterHashes += 1
            }
            guard afterHashes < source.count, source[afterHashes] == quote else { return nil }
            let pounds = afterHashes - index
            if matches(tripleQuote, at: afterHashes) {
                return Opening(pounds: pounds, multiline: true, end: afterHashes + 3)
            }

            return Opening(pounds: pounds, multiline: false, end: afterHashes + 1)
        }

        var stack: [Frame] = [.code(parens: -1)]
        var index = 0
        while index < source.count {
            switch stack[stack.count - 1] {
            case let .code(parens):
                if matches(lineCommentOpen, at: index) {
                    var end = index
                    while end < source.count, source[end] != newline {
                        end += 1
                    }
                    keepComment(index ..< end)
                    index = end
                } else if matches(blockCommentOpen, at: index) {
                    keepComment(index ..< index + 2)
                    stack.append(.blockComment(depth: 1))
                    index += 2
                } else if let opening = stringOpening(at: index) {
                    keep(index ..< opening.end, asExample: true)
                    stack.append(.string(pounds: opening.pounds, multiline: opening.multiline))
                    index = opening.end
                } else {
                    // The one byte of code that belongs to the string around it is the parenthesis
                    // closing an interpolation; everything else here is code.
                    var closesAnInterpolation = false
                    if parens > 0, source[index] == openParen {
                        stack[stack.count - 1] = .code(parens: parens + 1)
                    } else if parens > 0, source[index] == closeParen {
                        if parens == 1 {
                            stack.removeLast()
                            closesAnInterpolation = true
                        } else {
                            stack[stack.count - 1] = .code(parens: parens - 1)
                        }
                    }
                    keep(index ..< index + 1, asExample: closesAnInterpolation)
                    index += 1
                }

            case let .blockComment(depth):
                if matches(blockCommentOpen, at: index) {
                    stack[stack.count - 1] = .blockComment(depth: depth + 1)
                    keepComment(index ..< index + 2)
                    index += 2
                } else if matches(blockCommentClose, at: index) {
                    if depth == 1 {
                        stack.removeLast()
                    } else {
                        stack[stack.count - 1] = .blockComment(depth: depth - 1)
                    }
                    keepComment(index ..< index + 2)
                    index += 2
                } else {
                    keepComment(index ..< index + 1)
                    index += 1
                }

            case let .string(pounds, multiline):
                if source[index] == backslash, hashes(pounds, at: index + 1) {
                    let afterEscape = index + 1 + pounds
                    if afterEscape < source.count, source[afterEscape] == openParen {
                        keep(index ..< afterEscape + 1, asExample: true)
                        stack.append(.code(parens: 1))
                        index = afterEscape + 1
                    } else {
                        // Kept out of both halves. A literal's text is joined to the letter naming
                        // the escape otherwise, and reads as one name that nothing wrote.
                        index = min(afterEscape + 1, source.count)
                    }
                } else if multiline, matches(tripleQuote, at: index), hashes(pounds, at: index + 3) {
                    stack.removeLast()
                    keep(index ..< index + 3 + pounds, asExample: true)
                    index += 3 + pounds
                } else if !multiline, source[index] == quote, hashes(pounds, at: index + 1) {
                    stack.removeLast()
                    keep(index ..< index + 1 + pounds, asExample: true)
                    index += 1 + pounds
                } else if !multiline, source[index] == newline {
                    // Source that does not compile. Closing the literal here stops the scan reading the
                    // rest of the file as one runaway string, which would hide every name below it.
                    stack.removeLast()
                    index += 1
                } else {
                    keep(index ..< index + 1, asExample: true)
                    index += 1
                }
            }
        }

        blankBacktickedSignatureLabels(in: &comment, alsoIn: &example)

        return Split(code: code, example: example, comment: comment)
    }

    /// Blanks the argument labels of a backticked Swift signature — `` `events(forToolUse:on:) ` `` — out of the comment half, and out of the example half at the same positions.
    ///
    /// A symbol link in double backticks, which the doc compiler resolves against the compiler's own declarations, is read the same way.
    ///
    /// A labelled signature spelled in backticks is how this tree names the function a doc comment describes; the labels are its parameter names, not invented fixture names, and reading them as sightings is a parse artefact rather than a real leak. Scoped to comments only — a backtick span in a string literal, a fixture, or a non-Swift document is read exactly as before, so a name that really is invented cannot hide behind a pair of backticks anywhere else in the tree.
    ///
    /// A span counts as a signature only once it holds both a `(` and a `:`; a bare backticked word — `` `HealthKit` `` — has neither and is untouched. Within a qualifying span, only a token immediately followed by `:` is blanked, so the base function name before the parenthesis, and anything that is not itself a label, is still read and still held to the permit list.
    ///
    /// A closing backtick is only honored on the same line as the one that opened it: an unpaired backtick, or a fenced block whose triple backticks pair across lines, would otherwise open a span running to the next backtick anywhere later in the comment half, however many lines away — arbitrarily widening the exemption rather than narrowing it, which a privacy gate must never do.
    private static func blankBacktickedSignatureLabels(in comment: inout [UInt8], alsoIn example: inout [UInt8]) {
        var index = comment.startIndex
        while index < comment.endIndex {
            guard comment[index] == backtick else {
                index += 1
                continue
            }
            let openLength = backtickRun(in: comment, at: index)
            // One backtick is a code span and two are a symbol link; a longer run is a fence, which is never a span here.
            guard openLength <= 2 else {
                index += openLength
                continue
            }
            let lineEnd = comment[(index + openLength)...].firstIndex(of: newline) ?? comment.endIndex
            guard let close = closingBacktick(in: comment, from: index + openLength, before: lineEnd, length: openLength) else {
                index += openLength
                continue
            }
            let span = index + openLength ..< close
            if span.contains(where: { comment[$0] == openParen }), span.contains(where: { comment[$0] == colon }) {
                blankArgumentLabels(in: span, comment: &comment, example: &example)
            }
            index = close + openLength
        }
    }

    /// The length of the run of backticks starting at `index`.
    private static func backtickRun(in bytes: [UInt8], at index: Int) -> Int {
        var end = index
        while end < bytes.endIndex, bytes[end] == backtick {
            end += 1
        }
        return end - index
    }

    /// The start of the first run of exactly `length` backticks in `start ..< limit`, or nil.
    private static func closingBacktick(in bytes: [UInt8], from start: Int, before limit: Int, length: Int) -> Int? {
        var index = start
        while index < limit {
            guard bytes[index] == backtick else {
                index += 1
                continue
            }
            let run = backtickRun(in: bytes, at: index)
            if run == length {
                return index
            }
            index += run
        }
        return nil
    }

    /// Blanks every identifier in `range` that is immediately followed by `:`, in both halves alike.
    private static func blankArgumentLabels(in range: Range<Int>, comment: inout [UInt8], example: inout [UInt8]) {
        var index = range.lowerBound
        while index < range.upperBound {
            guard isIdentifierByte(comment[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < range.upperBound, isIdentifierByte(comment[end]) {
                end += 1
            }
            if end < comment.endIndex, comment[end] == colon {
                for labelIndex in index ..< end {
                    comment[labelIndex] = space
                    example[labelIndex] = space
                }
            }
            index = end
        }
    }

    /// A token's text.
    ///
    /// The bytes are alphanumerics or `_` by construction, so each one is a single ASCII scalar and the conversion is exact rather than a decode that could fail.
    private static func text(of token: ArraySlice<UInt8>) -> String {
        String(token.map { Character(UnicodeScalar($0)) })
    }

    // MARK: - Byte classes

    private static let tripleQuote = Array("\"\"\"".utf8)
    private static let lineCommentOpen = Array("//".utf8)
    private static let blockCommentOpen = Array("/*".utf8)
    private static let blockCommentClose = Array("*/".utf8)

    private static func isUppercase(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
    }

    private static func isLowercase(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        isUppercase(byte) || isLowercase(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "_")
    }
}

extension ExampleNameScanner {
    /// A name read out of a file, and the line it stands on.
    struct Sighting: Equatable {
        let name: String
        let line: Int
    }

    /// The two halves of a Swift file, each the length of the source it came from — plus the comments on their own, which are a part of the second.
    struct Split {
        /// Everything outside a comment or a string literal, with the rest blanked.
        let code: [UInt8]

        /// Every comment and every string literal, with the rest blanked.
        ///
        /// A string interpolation is code, and is blanked here along with everything else outside a literal.
        let example: [UInt8]

        /// Every comment and nothing else: the example half with its string literals blanked too.
        ///
        /// Kept apart for the checks that govern prose about the code and must not govern test data — a timestamp in a string literal is an input, and the same characters in a comment are a claim about when something happened.
        let comment: [UInt8]

        /// Every string literal and nothing else: the example half with its comments blanked, newlines kept.
        var literals: [UInt8] {
            zip(example, comment).map { $1 == ExampleNameScanner.space || $0 == ExampleNameScanner.newline ? $0 : ExampleNameScanner.space }
        }
    }

    /// A string literal's opening delimiter: how many `#` guard it, whether it is a multi-line literal, and where the delimiter ends.
    struct Opening {
        let pounds: Int
        let multiline: Bool
        let end: Int
    }

    /// Where the scan is, which is a stack because comments nest, and because a string interpolation holds code that can open another string.
    enum Frame {
        /// `parens` is `-1` for the file itself and counts the open parentheses of a string interpolation, which closes when the count reaches zero.
        case code(parens: Int)
        case blockComment(depth: Int)
        case string(pounds: Int, multiline: Bool)
    }
}
