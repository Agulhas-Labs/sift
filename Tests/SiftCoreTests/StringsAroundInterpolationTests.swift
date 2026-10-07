//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which matches around interpolations the strings answer lists and which it only counts: a literal sharing one word with the query never pushes the real site out.
@Suite(.temporaryDirectories)
struct StringsAroundInterpolationTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "interpolation fixture")
        return try SiftEngine(directory: root)
    }

    /// Twenty-five files each holding `"\(n) lines"`, which shares only "lines" with the queries here, then the pager whose wording the queries are.
    private static var crowd: [String: String] {
        var files: [String: String] = [:]
        for number in 1 ... 25 {
            let name = String(format: "Noise%02d", number)
            files["Sources/App/\(name).swift"] = """
            struct \(name) {
                func label(n: Int) -> String {
                    "\\(n) lines"
                }
            }
            """
        }
        files["Sources/App/Pager.swift"] = """
        struct Pager {
            func footer(n: Int, unit: String) -> String {
                "truncated: \\(n) more \\(unit)"
            }
        }
        """
        return files
    }

    private static var pagerSite: String {
        "  Pager.footer(n:unit:) — Sources/App/Pager.swift:3: \"truncated: \\(n) more \\(unit)\""
    }

    private static func oneWordHeading(limit: Int) -> String {
        "literals with interpolations, matched around them on only one word of literal text, a word matched this way on at most \(limit) production lines (each \\(…) read as some of the query's text, or none):"
    }

    @Test
    func aOneWordMatchOnARareWordIsListedWhenNothingElseListsAndTheCommonWordIsCounted() throws {
        let engine = try Self.makeRepo(files: Self.crowd)

        let output = try engine.strings(query: "more member lines")

        #expect(output.contains(Self.oneWordHeading(limit: 8)))
        #expect(output.contains(Self.pagerSite))
        #expect(output.contains("  25 more lines match it on only one word of literal text, tests included, not listed — \"lines\" 25; add a word to narrow"))
        #expect(!output.contains("Sources/App/Noise01.swift:3"))
    }

    /// `count` production files each holding `"\(n) crates"`, and two test files holding the same.
    private static func crates(count: Int) -> [String: String] {
        var files: [String: String] = [:]
        for number in 1 ... count {
            files["Sources/App/Crate\(number).swift"] = "struct Crate\(number) {\n    func label(n: Int) -> String {\n        \"\\(n) crates\"\n    }\n}\n"
        }
        for folder in ["A", "B"] {
            files["Tests/\(folder)/DepotStoreTests.swift"] = "import Testing\n\nstruct DepotStoreTests {\n    func label(n: Int) -> String {\n        \"\\(n) crates\"\n    }\n}\n"
        }
        return files
    }

    @Test
    func aWordOnEightProductionLinesIsListedTestsAside() throws {
        let engine = try Self.makeRepo(files: Self.crates(count: 8))

        let output = try engine.strings(query: "twelve crates")

        #expect(output.contains(Self.oneWordHeading(limit: 8)))
        #expect(output.contains("  Crate8.label(n:) — Sources/App/Crate8.swift:3: \"\\(n) crates\""))
        #expect(!output.contains("DepotStoreTests.swift:5"))
        #expect(output.contains("  2 more lines match it on only one word of literal text, tests included, not listed — \"crates\" 2; add a word to narrow"))
    }

    @Test
    func aWordOnNineProductionLinesIsCounted() throws {
        let engine = try Self.makeRepo(files: Self.crates(count: 9))

        let output = try engine.strings(query: "twelve crates")

        #expect(!output.contains("Sources/App/Crate8.swift:3"))
        #expect(output.hasSuffix("\nno Swift string literal contains it either\n11 lines match it around interpolations on only one word of literal text, tests included, not listed — \"crates\" 11; add a word to narrow"))
        #expect(!output.contains("literals with interpolations, matched around them"))
    }

    @Test
    func aPlainAnswerGainsOnlyTheCountLine() throws {
        var files = Self.crates(count: 1)
        files["Sources/App/Plain.swift"] = "struct Plain {\n    let label = \"twelve 5 crates\"\n}\n"
        let engine = try Self.makeRepo(files: files)

        let output = try engine.strings(query: "twelve 5 crates")

        #expect(output.hasSuffix("\n  Plain.label — Sources/App/Plain.swift:2: \"twelve 5 crates\"\n3 lines match it around interpolations on only one word of literal text, tests included, not listed — \"crates\" 3; add a word to narrow"))
        #expect(!output.contains("literals with interpolations, matched around them"))
    }

    @Test
    func theCountNamesEachWordInQueryOrder() throws {
        var files = Self.crates(count: 9)
        for number in 1 ... 9 {
            files["Sources/App/Twelve\(number).swift"] = "struct Twelve\(number) {\n    func label(n: Int) -> String {\n        \"twelve \\(n)\"\n    }\n}\n"
        }
        let engine = try Self.makeRepo(files: files)

        let output = try engine.strings(query: "twelve crates")

        #expect(output.contains("\n20 lines match it around interpolations on only one word of literal text, tests included, not listed — \"twelve\" 9, \"crates\" 11; add a word to narrow"))
    }

    @Test(arguments: [
        "Sources/App/Plain.swift": "struct Plain {\n    let label = \"twelve 5 crates\"\n}\n",
        "Sources/App/Pair.swift": "struct Pair {\n    func label(n: Int) -> String {\n        \"twelve \\(n) crates\"\n    }\n}\n",
    ])
    func aRareOneWordMatchStaysCountedBesideAPlainOrTwoWordSite(path: String, source: String) throws {
        var files = Self.crates(count: 1)
        files[path] = source
        let engine = try Self.makeRepo(files: files)

        let output = try engine.strings(query: "twelve 5 crates")

        #expect(output.contains(path))
        #expect(!output.contains("Sources/App/Crate1.swift:3"))
        #expect(!output.contains(Self.oneWordHeading(limit: 8)))
    }

    @Test
    func aMatchOnTwoQueryWordsIsListedAheadOfTheOneWordCrowd() throws {
        let engine = try Self.makeRepo(files: Self.crowd)

        let output = try engine.strings(query: "truncated: 15 more member lines")

        #expect(output.contains(Self.pagerSite))
        #expect(output.contains("  25 more lines match it on only one word of literal text, tests included, not listed — \"lines\" 25; add a word to narrow"))
        #expect(!output.contains("Sources/App/Noise01.swift:3"))
        #expect(!output.contains("more — narrow the query"))
    }

    @Test
    func anAlignmentOnTwoQueryWordsIsPreferredToAnEarlierOneOnOne() throws {
        let source = """
        struct Pager {
            func footer(a: Int, b: Int) -> String {
                "\\(a) lines \\(b) member lines"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/App/Pager.swift": source])

        let output = try engine.strings(query: "5 member lines")

        #expect(output.contains("  Pager.footer(a:b:) — Sources/App/Pager.swift:3: \"\\(a) lines \\(b) member lines\""))
        #expect(!output.contains("only one word of literal text"))
    }

    @Test
    func aLongLiteralIsWindowedOnItsLongestRunOfMatchedText() throws {
        let padding = String(repeating: "filler words ", count: 8)
        let source = """
        struct Depot {
            func summary(inventory: Inventory) -> String {
                "\(padding)the quick alpha beta \\(inventory.count + 1_000_000_000 + 2_000_000_000 + 3_000_000) gamma delta \(padding)"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/App/Depot.swift": source])

        let output = try engine.strings(query: "the quick alpha beta 5 gamma delta")

        #expect(output.contains("  Depot.summary(inventory:) — Sources/App/Depot.swift:3: \"…"))
        #expect(output.contains("the quick alpha beta \\(inventory"))
    }

    @Test
    func aLongLiteralWithAnEscapeInTheMatchedTextIsWindowedOnTheMatch() throws {
        let padding = String(repeating: "filler words ", count: 8)
        let source = """
        struct Depot {
            func refusal(name: String) -> String {
                "\(padding)refused \\(name)\\n — it did not complete in time"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/App/Depot.swift": source])

        let output = try engine.strings(query: "refused depot\n — it did not complete in time")

        #expect(output.contains("  Depot.refusal(name:) — Sources/App/Depot.swift:3: \"…"))
        #expect(output.contains("\\n — it did not complete in time\""))
    }

    /// The shape of the strings answer's own count line: each noun takes its plural from an interpolation glued to it.
    private static var tally: String {
        """
        struct Tally {
            func line(hits: [String], catalogs: Int) -> String {
                "\\(hits.count) key\\(hits.count == 1 ? "" : "s") in \\(catalogs) catalog\\(catalogs == 1 ? "" : "s")"
            }
        }
        """
    }

    @Test(arguments: [
        "3 keys in 2 catalogs",
        "1 key in 1 catalog",
        "keys in 2 catalogs",
    ])
    func aPluralSuffixInterpolationMatchesTheWordWithAndWithoutIt(query: String) throws {
        let engine = try Self.makeRepo(files: ["Sources/App/Tally.swift": Self.tally])

        let output = try engine.strings(query: query)

        #expect(output.contains("  Tally.line(hits:catalogs:) — Sources/App/Tally.swift:3: \""))
        #expect(!output.contains("only one word of literal text"))
    }

    @Test
    func aNumberGluedToItsUnitMatchesAroundTheInterpolationPrintingIt() throws {
        let source = """
        struct Stopwatch {
            func line(milliseconds: Int) -> String {
                "\\(milliseconds)ms elapsed in total"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/App/Stopwatch.swift": source])

        let output = try engine.strings(query: "42ms elapsed in total")

        #expect(output.contains("  Stopwatch.line(milliseconds:) — Sources/App/Stopwatch.swift:3: \"\\(milliseconds)ms elapsed in total\""))
        #expect(!output.contains("no Swift string literal contains it either"))
    }

    /// Filler that takes a literal past the display cap.
    private static var padding: String {
        String(repeating: "filler words ", count: 8)
    }

    /// The strings answer for `query` over one production file holding `literal`, spelled as its source writes it.
    private static func answer(literal: String, query: String) throws -> String {
        let source = "struct Depot {\n    func label(x: Int, count: Int) -> String {\n        \"\(literal)\"\n    }\n}\n"
        return try makeRepo(files: ["Sources/App/Depot.swift": source]).strings(query: query)
    }

    @Test
    func aLongLiteralWhoseMatchedTextHoldsAnEscapedQuoteIsWindowedOnIt() throws {
        let output = try Self.answer(literal: Self.padding + #"the \"special\" value \(x) ok"#, query: #"the "special" value 5 ok"#)

        #expect(output.contains("  Depot.label(x:count:) — Sources/App/Depot.swift:3: \"…"))
        #expect(output.contains(#"the \"special\" value \(x) ok""#))
    }

    @Test
    func aLongLiteralWhoseMatchedTextHoldsAUnicodeEscapeIsWindowedOnIt() throws {
        let output = try Self.answer(literal: Self.padding + #"special\u{2014}value \(x) ok"#, query: "special\u{2014}value 5 ok")

        #expect(output.contains("  Depot.label(x:count:) — Sources/App/Depot.swift:3: \"…"))
        #expect(output.contains(#"special\u{2014}value \(x) ok""#))
    }

    @Test
    func theWindowIsFoundInTheMatchedSegmentNotInAnInterpolatedExpression() throws {
        let literal = #"\(summary(catalogs: count)) "# + Self.padding + #"in \(count) catalog\(count == 1 ? "" : "s")"#

        let output = try Self.answer(literal: literal, query: "in 2 catalogs")

        #expect(output.contains("  Depot.label(x:count:) — Sources/App/Depot.swift:3: \"…"))
        #expect(output.contains(#"in \(count) catalog\(count == 1 ? "" : "s")""#))
    }

    @Test
    func aLetterGluedToAnInterpolationIsNotPartOfAQueryWord() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/App/Manifest.swift": "struct Manifest {\n    let name = \"Package.swift\"\n}\n",
            "Sources/App/Globber.swift": "struct Globber {\n    func pattern(index: Int) -> String {\n        \"grep -n foo P\\(index).swift\"\n    }\n}\n",
        ])

        let output = try engine.strings(query: "Package.swift")

        #expect(output.contains("  Manifest.name — Sources/App/Manifest.swift:2: \"Package.swift\""))
        #expect(!output.contains("Sources/App/Globber.swift:3"))
        #expect(output.contains("1 line matches it around interpolations on only one word of literal text"))
    }
}
