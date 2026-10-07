//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the strings tool answering, never trapping on, queries an agent types that are not plain words: a leading symbol, symbols only, padding, a lone quote or escape, an embedded NUL or newline, combining marks and emoji, a path, a very long query.
@Suite(.temporaryDirectories)
struct StringsQueryInputClassTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "Hello %@": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Hello %@"}}}},
                "%lld items": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld items"}}}},
                "%@ against %@": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%@ against %@"}}}},
                "settings.title": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Settings"}}}},
                "temp": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "°C today"}}}},
                "progress": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "% complete"}}}}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(
            #"""
            struct Depot {
                func hello(name: String) -> String { String(localized: "Hello \(name)") }
                func items(count: Int) -> String { String(localized: "\(count) items") }
                let title = String(localized: "settings.title")
                func message(lines: Int, unit: String) -> String { "truncated: \(lines) more \(unit)" }
            }
            """#,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    /// Queries that start with a symbol and have a letter or digit after it, each with the catalog line it finds.
    static let leadingSymbolQueries: [(query: String, found: String)] = [
        (".title", #"settings.title = "Settings""#),
        ("°C", #"temp = "°C today""#),
        ("% complete", #"progress = "% complete""#),
        ("%lld", #"%lld items = "%lld items""#),
        ("%@ against", #"%@ against %@ = "%@ against %@""#),
        ("@ against", #"%@ against %@ = "%@ against %@""#),
        ("  Hello  ", "searched 1 catalog file"),
        ("%1$@", "searched 1 catalog file"),
        ("%#@count@", "searched 1 catalog file"),
        ("%arg days", "searched 1 catalog file"),
        ("👍 items", "searched 1 catalog file"),
        ("../etc/passwd", "searched 1 catalog file"),
        ("^Hello", "searched 1 catalog file"),
        ("\u{301}items", "searched 1 catalog file"),
        ("\0items", "searched 1 catalog file"),
        ("\nitems", "searched 1 catalog file"),
        (".truncated: 3 more lines", "Depot.swift:5"),
    ]

    @Test(arguments: leadingSymbolQueries)
    func aQueryStartingWithASymbolBeforeAWordIsAnswered(query: String, found: String) throws {
        let output = try Self.makeRepo().strings(query: query)

        #expect(output.contains(found), "\(query.debugDescription): \(output)")
    }

    /// The rest of the class: no word at all, padding, a lone quote, escape or format sign, combining marks, a path, an uppercase letter that lowercases to more than one scalar, a very long query.
    static let otherQueries: [String] = [
        "", " ", "%", "@", "\\", "\"", "'", "%@", "x%@", "%%%", "@#$!", "((", "[", ".*", "$", "\0", "\n",
        "Hel\nlo", "Hel\0lo", "e\u{301}te", "é", "İ items", "ǅ items", "Sources/App/Depot.swift", "Hello \\(name)",
        String(repeating: "a", count: 5000), String(repeating: "%a ", count: 400),
    ]

    @Test(arguments: otherQueries)
    func aQueryOfAnyShapeIsAnswered(query: String) throws {
        let output = try Self.makeRepo().strings(query: query)

        #expect(output.contains("searched 1 catalog file"), "\(query.debugDescription): \(output)")
    }

    /// Words are numbered from the first one the query holds, whatever comes before it, so each word's text is at its own index.
    @Test(arguments: [
        (".title", ["title"]),
        ("%@ against", ["against"]),
        ("  Hello  ", ["Hello"]),
        ("  hello  ", ["hello"]),
        ("°C", ["C"]),
        ("%lld items", ["lld", "items"]),
        ("a.b-c", ["a", "b", "c"]),
        ("%%%", []),
    ])
    func eachWordOfAQueryIsNumberedFromZero(query: String, words: [String]) {
        let prepared = InterpolationWildcard.Query(query)

        #expect(prepared.wordTexts == words)
        #expect(Set(prepared.words.compactMap(\.self)) == Set(words.indices))
    }
}
