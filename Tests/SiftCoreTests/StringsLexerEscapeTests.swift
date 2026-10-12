//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the literal-occurrence scan reading a literal the way Swift prints it: an escaped apostrophe, a quote inside a plain key, and a line of a multiline block.
@Suite(.temporaryDirectories)
struct StringsLexerEscapeTests {
    /// A repo whose one catalog holds the given key (already JSON-escaped) and whose one source file holds `source`.
    private static func makeRepo(jsonKey: String, source: String) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "\(jsonKey)": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "\(jsonKey)"}}}}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(source, to: "Sources/App/Main.swift", in: root)
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test
    func anEscapedApostropheIsReadAsTheApostropheItPrints() throws {
        let output = try Self.makeRepo(
            jsonKey: "it's %@",
            source: #"""
            func f(x: String) -> String { String(localized: "it\'s \(x)") }
            """#
        ).strings(query: "it's")

        #expect(output.contains("\"it's %@\": Sources/App/Main.swift:1"), Comment(rawValue: output))
        #expect(!output.contains("none — likely referenced through a generated accessor"), Comment(rawValue: output))
    }

    @Test
    func aPlainKeyHoldingAQuoteIsListedAtTheLiteralThatEscapesIt() throws {
        let output = try Self.makeRepo(
            jsonKey: #"He said \"hi\""#,
            source: #"""
            func f() -> String { String(localized: "He said \"hi\"") }
            """#
        ).strings(query: "He said")

        #expect(output.contains(#""He said \"hi\"": Sources/App/Main.swift:1"#), Comment(rawValue: output))
        #expect(!output.contains("none — likely referenced through a generated accessor"), Comment(rawValue: output))
    }

    @Test
    func anIndentedBlockLineSpellingTheKeyIsListedAtThatLine() throws {
        let output = try Self.makeRepo(
            jsonKey: "Hello %@",
            source: #"""
            func e(x: String) -> String {
                """
                Hello \(x)
                """
            }
            """#
        ).strings(query: "Hello")

        #expect(output.contains("\"Hello %@\": Sources/App/Main.swift:3"), Comment(rawValue: output))
        #expect(!output.contains("none — likely referenced through a generated accessor"), Comment(rawValue: output))
    }
}
