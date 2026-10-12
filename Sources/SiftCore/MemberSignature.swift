//
// Copyright © Agulhas Labs
//

/// A member's declaration lines up to, but not including, the `{` that opens its body.
///
/// A declaration with no body brace (a protocol requirement, a stored property, including one initialised by a closure) is returned whole, and an accessor clause with no bodies (`{ get set }`) stays part of the signature. A computed property whose accessors carry effects keeps them, without the bodies (`{ get async throws }`). The scan skips comments and string literals, raw and multi-line ones included, and braces inside parentheses or brackets (a closure in a default argument), so only the body's own opening brace ends the signature.
struct MemberSignature {
    private static let accessorWords: Set<String> = ["get", "set", "_modify", "_read", "mutating", "nonmutating", "async", "throws", "rethrows"]
    private static let effectWords: Set<String> = ["async", "throws", "rethrows"]
    private static let asciiOperatorCharacters: Set<Character> = Set("=<>!&|+-*/%^~.?")
    private static let operatorRanges: [ClosedRange<UInt32>] = [
        0xA1 ... 0xA7, 0xA9 ... 0xA9, 0xAB ... 0xAC, 0xAE ... 0xAE, 0xB0 ... 0xB1, 0xB6 ... 0xB6, 0xBB ... 0xBB, 0xBF ... 0xBF,
        0xD7 ... 0xD7, 0xF7 ... 0xF7, 0x2016 ... 0x2017, 0x2020 ... 0x2027, 0x2030 ... 0x203E, 0x2041 ... 0x2053,
        0x2055 ... 0x205E, 0x2190 ... 0x23FF, 0x2500 ... 0x2775, 0x2794 ... 0x2BFF, 0x2E00 ... 0x2E7F,
        0x3001 ... 0x3003, 0x3008 ... 0x3020, 0x3030 ... 0x3030,
        0x300 ... 0x36F, 0x1DC0 ... 0x1DFF, 0x20D0 ... 0x20FF, 0xFE00 ... 0xFE0F, 0xFE20 ... 0xFE2F, 0xE0100 ... 0xE01EF,
    ]

    static func lines(of source: [String]) -> [String] {
        let chars = Array(source.joined(separator: "\n"))
        guard var text = signature(in: chars) else { return source }
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The signature text, or `nil` where the declaration is served whole.
    private static func signature(in chars: [Character]) -> String? {
        guard let opening = bodyOpening(in: chars) else { return nil }
        let prefix = String(chars[..<opening])
        guard !declarationWords(in: chars[..<opening]).contains(where: { ["func", "init", "deinit"].contains($0) }),
              let clause = accessorClause(in: chars, opening: opening),
              !clause.headers.isEmpty
        else { return prefix }
        let tokens = clause.headers.flatMap { words(in: withoutParentheses($0)) }
        guard tokens.allSatisfy(accessorWords.contains) else { return prefix }
        if !clause.hasBodies {
            return String(chars[..<clause.end])
        }
        guard tokens.contains(where: effectWords.contains) else { return prefix }
        let headers = clause.headers.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return prefix + "{ " + headers.joined(separator: " ") + " }"
    }

    /// The index of the first `{` outside comments, strings, parentheses and brackets, or `nil` where none opens a body.
    ///
    /// A `{` after a top-level `=` opens an initialiser closure, not a body; the scan steps over it so observers after it still end the signature.
    private static func bodyOpening(in chars: [Character]) -> Int? {
        var depth = 0
        var assigned = false
        var index = 0
        while index < chars.count {
            if let past = trivia(in: chars, at: index) {
                index = past
                continue
            }
            switch chars[index] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "=" where depth == 0 && isAssignment(chars, index): assigned = true
            case "{" where depth == 0:
                if !assigned {
                    return index
                }
                if isObserverBlock(in: chars, opening: index) {
                    return index
                }
                index = closing(of: index, in: chars)
                continue
            default: break
            }
            index += 1
        }
        return nil
    }

    /// The index just past the `{...}` block opening at `opening`, skipping comments and string literals.
    private static func closing(of opening: Int, in chars: [Character]) -> Int {
        var depth = 0
        var index = opening
        while index < chars.count {
            if let past = trivia(in: chars, at: index) {
                index = past
                continue
            }
            if chars[index] == "{" {
                depth += 1
            } else if chars[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
            index += 1
        }
        return chars.count
    }

    private static func isAssignment(_ chars: [Character], _ index: Int) -> Bool {
        let before = index > 0 ? chars[index - 1] : " "
        let after = index + 1 < chars.count ? chars[index + 1] : " "
        return !isOperatorCharacter(before) && !isOperatorCharacter(after)
    }

    /// Whether the character is one Swift allows in an operator, the full set from the language's lexical structure.
    private static func isOperatorCharacter(_ char: Character) -> Bool {
        if asciiOperatorCharacters.contains(char) {
            return true
        }
        guard let value = char.unicodeScalars.first?.value, value > 0x7F else { return false }
        return operatorRanges.contains { $0.contains(value) }
    }

    /// Whether the block opening at `opening`, after an initial value, holds only `willSet` and `didSet` observers.
    private static func isObserverBlock(in chars: [Character], opening: Int) -> Bool {
        guard let clause = accessorClause(in: chars, opening: opening), clause.hasBodies, !clause.headers.isEmpty else { return false }
        return clause.headers.allSatisfy { header in
            let tokens = words(in: withoutParentheses(header))
            return !tokens.isEmpty && tokens.allSatisfy { $0 == "willSet" || $0 == "didSet" }
        }
    }

    /// The words of a declaration outside comments, string literals and parentheses, so attribute arguments and parameter lists never read as keywords.
    private static func declarationWords(in slice: ArraySlice<Character>) -> [String] {
        let chars = Array(slice)
        var kept = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            if let past = trivia(in: chars, at: index) {
                kept.append(" ")
                index = past
                continue
            }
            switch chars[index] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default:
                if depth == 0 {
                    kept.append(chars[index])
                }
            }
            index += 1
        }
        return words(in: kept)
    }

    /// The accessor block opening at `opening`: the text outside each nested body, where it closes, and whether any body was nested.
    private static func accessorClause(in chars: [Character], opening: Int) -> AccessorClause? {
        var headers: [String] = []
        var current = ""
        var hasBodies = false
        var depth = 1
        var index = opening + 1
        while index < chars.count {
            if let past = trivia(in: chars, at: index) {
                index = past
                continue
            }
            let char = chars[index]
            index += 1
            if char == "{" {
                if depth == 1 {
                    headers.append(current)
                    current = ""
                    hasBodies = true
                }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    if !current.allSatisfy(\.isWhitespace) {
                        headers.append(current)
                    }
                    return AccessorClause(headers: headers, end: index, hasBodies: hasBodies)
                }
            } else if depth == 1 {
                current.append(char)
            }
        }
        return nil
    }

    private static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
    }

    private static func withoutParentheses(_ text: String) -> String {
        var depth = 0
        var kept = ""
        for char in text {
            if char == "(" {
                depth += 1
            } else if char == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                kept.append(char)
            }
        }
        return kept
    }

    /// The index just past the comment or string literal starting at `index`, or `nil` where none starts there.
    private static func trivia(in chars: [Character], at index: Int) -> Int? {
        if let past = commentEnd(in: chars, at: index) {
            return past
        }
        guard let opening = stringOpening(in: chars, at: index) else { return nil }
        return stringEnd(in: chars, from: opening.quote, hashes: opening.hashes)
    }

    /// The index just past the comment starting at `index`, or `nil` where none starts there.
    private static func commentEnd(in chars: [Character], at index: Int) -> Int? {
        guard chars[index] == "/", index + 1 < chars.count else { return nil }
        if chars[index + 1] == "/" {
            var end = index
            while end < chars.count, chars[end] != "\n" {
                end += 1
            }
            return end
        }
        if chars[index + 1] == "*" {
            var end = index + 2
            while end + 1 < chars.count, !(chars[end] == "*" && chars[end + 1] == "/") {
                end += 1
            }
            return end + 2
        }
        return nil
    }

    /// The opening quote of the string literal that starts at `index` with its hash marks, or `nil` where none starts there.
    private static func stringOpening(in chars: [Character], at index: Int) -> (quote: Int, hashes: Int)? {
        var quote = index
        while quote < chars.count, chars[quote] == "#" {
            quote += 1
        }
        guard quote < chars.count, chars[quote] == "\"" else { return nil }
        return (quote, quote - index)
    }

    /// The index just past the string literal whose opening quote is at `start`, closed by its quote(s) and `hashes` hash marks.
    ///
    /// An interpolation is followed through the strings and comments inside it, with an explicit stack of the open contexts so nesting depth costs no call stack.
    private static func stringEnd(in chars: [Character], from start: Int, hashes: Int) -> Int {
        var stack = [openString(in: chars, at: start, hashes: hashes)]
        var index = start + (isRun(of: "\"", count: 3, in: chars, at: start) ? 3 : 1)
        while index < chars.count, let top = stack.last {
            switch top {
            case let .string(quotes, hashes):
                if chars[index] == "\\", isRun(of: "#", count: hashes, in: chars, at: index + 1) {
                    let interpolation = index + hashes + 1
                    if interpolation < chars.count, chars[interpolation] == "(" {
                        stack.append(.interpolation(depth: 1))
                    }
                    index = interpolation + 1
                } else if isRun(of: "\"", count: quotes, in: chars, at: index), isRun(of: "#", count: hashes, in: chars, at: index + quotes) {
                    index += quotes + hashes
                    stack.removeLast()
                } else if quotes == 1, chars[index] == "\n" {
                    index += 1
                    stack.removeLast()
                } else {
                    index += 1
                }
            case let .interpolation(depth):
                if let past = commentEnd(in: chars, at: index) {
                    index = past
                } else if let opening = stringOpening(in: chars, at: index) {
                    stack.append(openString(in: chars, at: opening.quote, hashes: opening.hashes))
                    index = opening.quote + (isRun(of: "\"", count: 3, in: chars, at: opening.quote) ? 3 : 1)
                } else {
                    if chars[index] == "(" {
                        stack[stack.count - 1] = .interpolation(depth: depth + 1)
                    } else if chars[index] == ")" {
                        if depth == 1 {
                            stack.removeLast()
                        } else {
                            stack[stack.count - 1] = .interpolation(depth: depth - 1)
                        }
                    }
                    index += 1
                }
            }
            if stack.isEmpty {
                return index
            }
        }
        return chars.count
    }

    private static func openString(in chars: [Character], at quote: Int, hashes: Int) -> Context {
        .string(quotes: isRun(of: "\"", count: 3, in: chars, at: quote) ? 3 : 1, hashes: hashes)
    }

    private static func isRun(of char: Character, count: Int, in chars: [Character], at index: Int) -> Bool {
        index + count <= chars.count && chars[index ..< index + count].allSatisfy { $0 == char }
    }
}

extension MemberSignature {
    private enum Context {
        case string(quotes: Int, hashes: Int)
        case interpolation(depth: Int)
    }

    private struct AccessorClause {
        let headers: [String]
        let end: Int
        let hasBodies: Bool
    }
}
