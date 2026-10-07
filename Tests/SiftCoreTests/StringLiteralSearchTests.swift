//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the source-literal half of the strings tool: wording traced to the Swift string literal holding it, with or without a catalog.
@Suite(.temporaryDirectories)
struct StringLiteralSearchTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "literal fixture")
        return try SiftEngine(directory: root)
    }

    private static var store: String {
        """
        struct DepotStore {
            // restock says "did not complete" — a comment, not wording
            func restock(underlying: String) throws -> String {
                "refused — \\(underlying) did not complete"
            }
        }
        """
    }

    @Test
    func aRepoWithoutCatalogsAnswersWithTheLiteralItsMethodAndItsLine() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.store])

        let output = try engine.strings(query: "did not complete")

        #expect(output.contains("no string catalogs (.xcstrings / .strings) in this repo"))
        #expect(output.contains("source literals (Swift string literals holding the wording, not catalog entries):"))
        #expect(output.contains("  DepotStore.restock(underlying:) — Sources/Depot/DepotStore.swift:4: \"refused — \\(underlying) did not complete\""))
    }

    @Test
    func aCommentHoldingTheWordingIsNotALiteral() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.store])

        let output = try engine.strings(query: "did not complete")

        #expect(!output.contains("DepotStore.swift:2"))
        #expect(output.contains("DepotStore.swift:4"))
    }

    @Test
    func anInterpolatedExpressionIsNotWording() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.store])

        let expressionAlone = try engine.strings(query: "underlying")
        let acrossIt = try engine.strings(query: "underlying) did")

        #expect(expressionAlone.contains("no Swift string literal contains it either"))
        #expect(!acrossIt.contains("source literals (Swift string literals holding the wording"))
        #expect(acrossIt.contains("literals with interpolations, matched around them on only one word of literal text"))
    }

    @Test
    func aCatalogMatchStaysFirstAndTheLiteralSectionFollowsIt() throws {
        let catalog = """
        {
          "sourceLanguage": "en",
          "strings": {
            "restock.failed": {
              "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": "Restock failed"}}
              }
            }
          },
          "version": "1.0"
        }
        """
        let source = """
        struct DepotStore {
            func restock() -> String {
                "restock failed at the depot"
            }
        }
        """
        let engine = try Self.makeRepo(files: [
            "Resources/Localizable.xcstrings": catalog,
            "Sources/Depot/DepotStore.swift": source,
        ])

        let output = try engine.strings(query: "restock failed")

        let catalogLine = try #require(output.range(of: "restock.failed = \"Restock failed\""))
        let heading = try #require(output.range(of: "source literals (Swift string literals holding the wording, not catalog entries):"))

        #expect(catalogLine.upperBound < heading.lowerBound)
        #expect(output.contains("  DepotStore.restock() — Sources/Depot/DepotStore.swift:3: \"restock failed at the depot\""))
    }

    @Test
    func aLineInsideAMultiLineLiteralMatches() throws {
        let source = """
        struct DepotStore {
            let help = \"\"\"
                Usage: depot restock
                  the shelf was left untouched
                \"\"\"
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": source])

        let output = try engine.strings(query: "left untouched")

        #expect(output.contains("  DepotStore.help — Sources/Depot/DepotStore.swift:4: \"the shelf was left untouched\""))
    }

    @Test
    func theSectionIsCappedAndSortedByPathThenLine() throws {
        let many = (1 ... 25).map { "let shelf\($0) = \"shelf empty\"" }.joined(separator: "\n")
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/B.swift": many,
            "Sources/Depot/A.swift": "let first = \"shelf empty\"",
        ])

        let output = try engine.strings(query: "shelf empty")

        let lines = output.split(separator: "\n").map(String.init)
        let heading = try #require(lines.firstIndex { $0.hasPrefix("source literals") })

        #expect(lines[heading + 1].hasPrefix("  first — Sources/Depot/A.swift:1:"))
        #expect(lines[heading + 2].hasPrefix("  shelf1 — Sources/Depot/B.swift:1:"))
        #expect(lines[heading + 20].hasPrefix("  shelf19 — Sources/Depot/B.swift:19:"))
        #expect(lines[heading + 21] == "  +6 more — narrow the query")
    }

    @Test
    func theLexerKeepsEscapesRawDelimitersAndTrailingCommentsInTheirPlace() {
        var lexer = SwiftLiteralLexer()

        let escaped = lexer.literals(on: #"let a = "say \"hi\" now" // "not this""#)
        let raw = lexer.literals(on: ##"let b = #"a "quoted" word"#"##)
        let nested = lexer.literals(on: #"let c = "x \(f("inner")) y""#)

        #expect(escaped.map(\.text) == [#"say \"hi\" now"#])
        #expect(raw.map(\.text) == [#"a "quoted" word"#])
        #expect(nested.map(\.text) == [#"x \(f("inner")) y"#, "inner"])
        #expect(nested.first?.contains("inner") == false)
    }

    @Test
    func aQueryWithAPlainQuoteMatchesALiteralSpelledWithAnEscapedOne() {
        var lexer = SwiftLiteralLexer()

        let literals = lexer.literals(on: #"let a = "already a comment — \"stock take\"""#)

        #expect(literals.first?.contains(#"comment — ""#) == true)
    }

    @Test
    func aQueryWithANewlineMatchesALiteralSpelledWithTheEscape() {
        var lexer = SwiftLiteralLexer()

        let literals = lexer.literals(on: #"let a = "shelf empty\nrestock now""#)

        #expect(literals.first?.contains("empty\nrestock") == true)
    }

    @Test
    func aRawStringMatchesOnlyItsUnchangedSpelling() {
        var lexer = SwiftLiteralLexer()

        let literals = lexer.literals(on: ##"let a = #"shelf \n empty"#"##)

        #expect(literals.first?.contains(#"shelf \n empty"#) == true)
        #expect(literals.first?.contains("shelf \n empty") == false)
    }

    @Test
    func theLexerSkipsBlockCommentsAcrossLines() {
        var lexer = SwiftLiteralLexer()

        let opening = lexer.literals(on: #"/* "commented" "#)
        let closing = lexer.literals(on: #"still */ let d = "live""#)

        #expect(opening.isEmpty)
        #expect(closing.map(\.text) == ["live"])
    }

    @Test
    func aStringLiteralNestedInAnInterpolationIsListedWithTheInnerText() throws {
        let source = """
        struct DepotStore {
            func greeting(name: String) -> String {
                "hello \\(name + "inner jaguar") outer"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": source])

        let output = try engine.strings(query: "jaguar")

        #expect(output.contains("  DepotStore.greeting(name:) — Sources/Depot/DepotStore.swift:3: \"inner jaguar\""))
    }

    @Test
    func theOuterLiteralStillMatchesAQueryInItsOwnText() throws {
        let source = """
        struct DepotStore {
            func greeting(name: String) -> String {
                "hello \\(name + "inner jaguar") outer"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": source])

        let output = try engine.strings(query: "outer")

        #expect(output.contains("  DepotStore.greeting(name:) — Sources/Depot/DepotStore.swift:3: \"hello \\(name + \"inner jaguar\") outer\""))
    }

    @Test
    func aDoublyNestedLiteralIsFound() {
        var lexer = SwiftLiteralLexer()

        let found = lexer.literals(on: #"let a = "one \(two("mid \(three("badger")) tail")) end""#)

        #expect(found.map(\.text) == [
            #"one \(two("mid \(three("badger")) tail")) end"#,
            #"mid \(three("badger")) tail"#,
            "badger",
        ])
    }

    @Test
    func aNestedLiteralInsideAMultiLineLiteralIsFound() throws {
        let source = """
        struct DepotStore {
            let help = \"\"\"
                Usage: \\(label("depot badger"))
                \"\"\"
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": source])

        let output = try engine.strings(query: "badger")

        #expect(output.contains("  DepotStore.help — Sources/Depot/DepotStore.swift:3: \"depot badger\""))
    }

    @Test
    func aNestedLiteralInARawLiteralIsFound() {
        var lexer = SwiftLiteralLexer()

        let found = lexer.literals(on: ##"let e = #"outer \#(label("inner badger")) tail"#"##)

        #expect(found.map(\.text) == [
            "outer \\#(label(\"inner badger\")) tail",
            "inner badger",
        ])
    }

    private static var pager: String {
        """
        struct DepotStore {
            func footer(remaining: Int, unit: String) -> String {
                "truncated: \\(remaining) more \\(unit) — pass offset"
            }
            func tally(count: Int, noun: String, total: Int) -> String {
                "\\(count) \\(noun) of \\(total)"
            }
            func restock(verb: String) -> String {
                "\\(verb)ing crates"
            }
        }
        """
    }

    private static var aroundHeading: String {
        "literals with interpolations, matched around them (each \\(…) read as some of the query's text, or none):"
    }

    private static var footerSite: String {
        "  DepotStore.footer(remaining:unit:) — Sources/Depot/DepotStore.swift:3: \"truncated: \\(remaining) more \\(unit) — pass offset\""
    }

    @Test(arguments: [
        "15 more member lines — pass",
        "truncated: 15 more member lines",
        "truncated: 15 more member lines — pass",
    ])
    func wordingThatSpansAnInterpolationIsMatchedAroundIt(query: String) throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.pager])

        let output = try engine.strings(query: query)

        #expect(output.contains(Self.aroundHeading))
        #expect(output.contains(Self.footerSite))
        #expect(!output.contains("source literals (Swift string literals holding the wording"))
    }

    @Test
    func anUppercaseLetterMakesTheMatchAroundAnInterpolationCaseSensitive() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.pager])

        #expect(try engine.strings(query: "15 More member").contains(Self.aroundHeading) == false)
        #expect(try engine.strings(query: "15 more Member lines — pass").contains(Self.footerSite))
    }

    @Test
    func aLiteralHoldingTheQueryIsListedOnlyAsAPlainMatch() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.pager])

        let output = try engine.strings(query: "more ")

        #expect(output.contains("source literals (Swift string literals holding the wording, not catalog entries):"))
        #expect(output.contains(Self.footerSite))
        #expect(!output.contains(Self.aroundHeading))
    }

    @Test(arguments: [
        "seven apples",
        "seven apples of ten",
        "sorting crates",
    ])
    func interpolationsWithoutAWholeLiteralWordBesideThemMatchNothing(query: String) throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": Self.pager])

        let output = try engine.strings(query: query)

        #expect(output.contains("no Swift string literal contains it either"))
    }

    @Test
    func aLongLiteralMatchedAroundAnInterpolationIsWindowedOnTheTextItMatched() throws {
        let padding = String(repeating: "filler words ", count: 8)
        let source = """
        struct DepotStore {
            func footer(unit: String) -> String {
                "\(padding)then \\(unit) remain in the depot"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": source])

        let output = try engine.strings(query: "twelve crates remain in the depot")

        #expect(output.contains("DepotStore.footer(unit:) — Sources/Depot/DepotStore.swift:3: \"…"))
        #expect(output.contains("then \\(unit) remain in the depot\""))
    }

    @Test
    func aLongQueryAgainstManySpacedInterpolationsAnswersPromptly() {
        let segments = [""] + Array(repeating: " ", count: 13) + [""]
        let query = (1 ... 24).map { "word\($0)" }.joined(separator: " ")
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            #expect(InterpolationWildcard.match(of: InterpolationWildcard.Query(query), in: segments) == nil)
        }

        #expect(elapsed < .seconds(2))
    }
}
