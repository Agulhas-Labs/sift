//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how the strings answer spells catalog text, finds a key's interpolated spelling through escapes, and which one-word matches around interpolations it lists.
@Suite(.temporaryDirectories)
struct StringsLowsTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "strings fixture")
        return try SiftEngine(directory: root)
    }

    /// An `.xcstrings` catalog whose source language holds `entries`, key to value.
    private static func catalog(_ entries: [String: String], sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let strings = entries.mapValues { ["localizations": ["en": ["stringUnit": ["state": "translated", "value": $0]]]] }
        let data = try JSONSerialization.data(withJSONObject: ["sourceLanguage": "en", "strings": strings, "version": "1.0"], options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8), sourceLocation: sourceLocation)
    }

    private static func lines(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Escaping

    @Test
    func aValueIsPrintedWithItsBackslashesAndQuotesEscapedAsALiteralSpellsThem() throws {
        let engine = try Self.makeRepo(files: [
            "Resources/Localizable.xcstrings": Self.catalog(["path": #"C:\x\"y"#, "slash": #"back\nslash"#, "real": "back\nslash"]),
            "Sources/App/Main.swift": "struct Main {}\n",
        ])

        let path = try Self.lines(engine.strings(query: "C:"))
        let back = try Self.lines(engine.strings(query: "back"))

        #expect(path.contains(#"  path = "C:\\x\\\"y""#), "\(path)")
        #expect(back.contains(#"  slash = "back\\nslash""#), "\(back)")
        #expect(back.contains(#"  real = "back\nslash""#), "\(back)")
    }

    @Test
    func theEchoEscapesABackslashAndAQuote() throws {
        let engine = try Self.makeRepo(files: ["Sources/App/Main.swift": "struct Main {}\n"])

        let lines = try Self.lines(engine.strings(query: #"C:\x"y"#))

        #expect(lines.count > 2 && lines[1] == #"strings "C:\\x\"y""#, "\(lines)")
    }

    // MARK: Interpolated spellings through escapes

    @Test(arguments: [
        #"func say(x: String) -> String { String(localized: "Say \"\(x)\"") }"#,
        ##"func say(x: String) -> String { String(localized: #"Say "\#(x)""#) }"##,
    ])
    func aKeyWithQuotesIsSpelledByAnInterpolatedLiteralThatEscapesThem(member: String) throws {
        let engine = try Self.makeRepo(files: [
            "Resources/Localizable.xcstrings": Self.catalog([#"Say "%@""#: #"Say "%@""#]),
            "Sources/App/Main.swift": "struct Main {\n    \(member)\n}\n",
        ])

        let output = try engine.strings(query: "Say")

        #expect(Self.lines(output).contains(#"  "Say \"%@\"": Sources/App/Main.swift:2"#), Comment(rawValue: output))
    }

    // MARK: The one-word fallback

    /// A file per word of `words`, `count` of each, holding `"\(n) <word> \(n)"`, which matches a query holding the word on that word alone.
    private static func oneWordFiles(_ words: [String], count: Int) -> [String: String] {
        var files: [String: String] = [:]
        for word in words {
            for number in 1 ... count {
                let name = word.prefix(1).uppercased() + word.dropFirst() + "\(number)"
                files["Sources/App/\(name).swift"] = "struct \(name) {\n    func label(n: Int) -> String {\n        \"\\(n) \(word) \\(n)\"\n    }\n}\n"
            }
        }
        return files
    }

    @Test
    func theFallbackListsNoMoreThanItsLimitAcrossEveryWord() throws {
        let words = ["alpha", "bravo", "charlie", "delta", "echo"]
        let engine = try Self.makeRepo(files: Self.oneWordFiles(words, count: 5))

        let output = try engine.strings(query: words.joined(separator: " "))

        #expect(!output.contains("literals with interpolations, matched around them"), Comment(rawValue: output))
        #expect(output.hasSuffix("\nno Swift string literal contains it either\n25 lines match it around interpolations on only one word of literal text, tests included, not listed — \"alpha\" 5, \"bravo\" 5, \"charlie\" 5, \"delta\" 5, \"echo\" 5; add a word to narrow"), Comment(rawValue: output))
    }

    @Test
    func aStopWordIsNeverListedAndTheNothingContainsItLineStays() throws {
        let engine = try Self.makeRepo(files: Self.oneWordFiles(["the"], count: 3))

        let output = try engine.strings(query: "could not connect to the server at that address")

        #expect(!output.contains("Sources/App/The1.swift"), Comment(rawValue: output))
        #expect(output.hasSuffix("\nno Swift string literal contains it either\n3 lines match it around interpolations on only one word of literal text, tests included, not listed — \"the\" 3; add a word to narrow"), Comment(rawValue: output))
    }

    /// Ten files holding `"mike \(i)"`, then `Oscar.swift` holding `literal` on line 3.
    private static func mikeFiles(oscar literal: String) -> [String: String] {
        var files: [String: String] = [:]
        for number in 1 ... 10 {
            files["Sources/App/Mike\(number).swift"] = "struct Mike\(number) {\n    func label(i: Int) -> String {\n        \"mike \\(i)\"\n    }\n}\n"
        }
        files["Sources/App/Oscar.swift"] = "struct Oscar {\n    func label(i: Int, j: Int) -> String {\n        \"\(literal)\"\n    }\n}\n"
        return files
    }

    @Test
    func aLineIsCreditedToEveryWordItMatchesSoTheRareWordsOnlySiteIsListed() throws {
        let engine = try Self.makeRepo(files: Self.mikeFiles(oscar: #"mike \(i) zzz \(j) oscar"#))

        let output = try engine.strings(query: "mike foo oscar")

        #expect(output.contains(#"  Oscar.label(i:j:) — Sources/App/Oscar.swift:3: "mike \(i) zzz \(j) oscar""#), Comment(rawValue: output))
        #expect(output.contains("  10 more lines match it on only one word of literal text, tests included, not listed — \"mike\" 10; add a word to narrow"), Comment(rawValue: output))
        #expect(!output.contains("Sources/App/Mike1.swift"), Comment(rawValue: output))
    }

    @Test
    func aLongLiteralListedForItsRareWordIsWindowedOnThatWord() throws {
        let filler = Array(repeating: "zzz", count: 30).joined(separator: " ")
        let engine = try Self.makeRepo(files: Self.mikeFiles(oscar: "mike \\(i) \(filler) \\(j) oscar"))

        let output = try engine.strings(query: "mike foo oscar")
        let site = Self.lines(output).first { $0.contains("Sources/App/Oscar.swift:3") }

        #expect(site?.hasSuffix(#"\(j) oscar""#) == true, Comment(rawValue: output))
    }

    @Test
    func theFallbackStaysQuietBesideACatalogHit() throws {
        let engine = try Self.makeRepo(files: [
            "Resources/Localizable.xcstrings": Self.catalog(["signal": "romeo sierra tango"]),
            "Sources/App/Main.swift": "struct Main {\n    func label(x: Int) -> String {\n        \"\\(x) tango\"\n    }\n}\n",
        ])

        let output = try engine.strings(query: "romeo sierra tango")

        #expect(output.contains(#"  signal = "romeo sierra tango""#), Comment(rawValue: output))
        #expect(!output.contains("literals with interpolations, matched around them"), Comment(rawValue: output))
        #expect(output.hasSuffix("\n1 line matches it around interpolations on only one word of literal text, tests included, not listed — \"tango\" 1; add a word to narrow"), Comment(rawValue: output))
    }
}
