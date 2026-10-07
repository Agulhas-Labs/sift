//
// Copyright © Agulhas Labs
//

/// Reads the module an `import` line names, without a parse.
///
/// Agrees with the imports the index stores for a file: a scoped import (`import struct XCTest.XCTestCase`) counts as its module, any other import as its path as written (`Foo.Sub`), and attributes (`@testable`, `@_exported`, `@_spi(…)`) and an access level before it are skipped. A caller feeds it the lines that begin in code, so an import inside a comment or a multi-line literal is never read; an import inside a conditional-compilation block is read like any other, as the index reads it.
struct ImportLineReader {
    private static let accessLevels: Set<Substring> = ["public", "package", "internal", "fileprivate", "private"]
    private static let kinds: Set<Substring> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]

    /// Every module `source` imports, in order, read line by line with the lexer keeping comments and multi-line literals out.
    static func modules(inSource source: String) -> [String] {
        var lexer = SwiftLiteralLexer()
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if lexer.isInCode, let module = module(inLine: line) {
                found.append(module)
            }
            _ = lexer.literals(on: line)
        }
        return found
    }

    /// The module `line` imports, or `nil` when the line is no import.
    static func module(inLine line: Substring) -> String? {
        var rest = line.drop(while: isBlank)
        guard let first = rest.first, first == "i" || first == "@" || first == "p" || first == "f" else {
            return nil
        }
        while true {
            if rest.first == "@" {
                rest = skipAttribute(rest)
            } else if let word = leadingWord(of: rest), accessLevels.contains(word) {
                rest = rest.dropFirst(word.count).drop(while: isBlank)
            } else {
                break
            }
        }
        guard let keyword = leadingWord(of: rest), keyword == "import" else {
            return nil
        }
        rest = rest.dropFirst(keyword.count)
        guard rest.first.map(isBlank) == true else {
            return nil
        }
        rest = rest.drop(while: isBlank)
        var isScoped = false
        if let word = leadingWord(of: rest), kinds.contains(word) {
            let after = rest.dropFirst(word.count)
            if after.first.map(isBlank) == true {
                isScoped = true
                rest = after.drop(while: isBlank)
            }
        }
        let path = pathText(of: rest)
        guard !path.isEmpty else {
            return nil
        }
        return isScoped ? String(path.prefix { $0 != "." }) : String(path)
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func leadingWord(of text: Substring) -> Substring? {
        let word = text.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return word.isEmpty ? nil : word
    }

    /// `text` past one leading attribute and the blanks after it.
    private static func skipAttribute(_ text: Substring) -> Substring {
        var rest = text.dropFirst()
        rest = rest.drop { $0.isLetter || $0.isNumber || $0 == "_" }
        if rest.first == "(", let close = rest.firstIndex(of: ")") {
            rest = rest[rest.index(after: close)...]
        }
        return rest.drop(while: isBlank)
    }

    /// The dotted path at the start of `text`, ending at a blank, a semicolon or a comment.
    private static func pathText(of text: Substring) -> Substring {
        var end = text.startIndex
        while end < text.endIndex {
            let character = text[end]
            if isBlank(character) || character == ";" {
                break
            }
            if character == "/", text[text.index(after: end)...].first.map({ $0 == "/" || $0 == "*" }) == true {
                break
            }
            end = text.index(after: end)
        }
        return text[text.startIndex ..< end]
    }
}
