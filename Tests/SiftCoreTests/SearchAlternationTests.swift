//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `a|b` on every field and `/regex/` on `path:` and `sig:`, the forms callers generalise from `name:` and were refused for.
///
/// Each query below is one a caller wrote and had refused, rewritten onto a fixture; the guards beside them pin what the fields still refuse.
struct SearchAlternationTests {
    /// Two files in different places, each declaring the same call and the same name, so a path term has something to tell apart.
    private static let tree: [SourceFile] = [
        SourceFile(path: "Sources/App/Tally.swift", text: """
        import Foundation

        struct Searcher {
            func skipped() { restock() }
            func Skipped() {}
        }

        enum Searching {
            case idle
        }

        class Searched {
            static func closed() async throws {}
        }

        protocol Searchable {}
        """),
        SourceFile(path: "Sources/App/Other.swift", text: """
        struct Depot: Equatable {
            func skipped() { restock() }
            func shelves() -> [Shelf] { [] }
            func labels() -> [String] { [] }
        }

        extension Shelf {
            private func emptied() {}
        }
        """),
    ]

    /// The qualified names `query` finds across the fixture files, each file read only when the query's path terms admit it, as a search reads a tree.
    private static func found(_ query: String) throws -> [String] {
        let parsed = try StructuralQuery(query)
        return tree.filter { parsed.admitsPath($0.path) }
            .flatMap { StructuralMatcher.matches(in: $0.text, path: $0.path, query: parsed) }
            .map { String($0.qualifiedName.prefix { $0 != "(" }) }
            .sorted()
    }

    /// The text a query that fails to parse is refused with, or an empty string when it parses.
    private static func refusal(_ query: String) -> String {
        do {
            _ = try StructuralQuery(query)
            return ""
        } catch {
            return String(describing: error)
        }
    }

    /// The echo line an answer for `query` opens with.
    private static func echo(_ query: String) throws -> String {
        let result = StructuralSearch.Result(matches: [], filesScanned: 1)
        return try SearchRenderer.render(result: result, query: StructuralQuery(query)).split(separator: "\n").first.map(String.init) ?? ""
    }

    // MARK: The refused calls, rewritten

    /// A name regex beside a path regex: the path term picks the file, the name term the declaration in it.
    @Test
    func aPathRegexAnswersBesideANameRegex() throws {
        #expect(try Self.found("name:/[Ss]kipped/ path:/Tally|Progress/") == ["Searcher.Skipped", "Searcher.skipped"])
    }

    /// A signature regex beside an owner: the regex's escaped bracket reads as written, and only the signature naming it answers.
    @Test
    func aSignatureRegexAnswersBesideAnOwner() throws {
        #expect(try Self.found(#"owner:Depot sig:/Shelf\]/"#) == ["Depot.shelves"])
    }

    /// A path regex beside a call: only the file the regex admits is read.
    @Test
    func aPathRegexAnswersBesideACall() throws {
        #expect(try Self.found("kind:func calls:restock path:/Other/") == ["Depot.skipped"])
    }

    /// Kind alternatives written three ways answer the same three declarations, and the protocol none of them names stays out.
    @Test
    func kindAlternativesAnswerInAnyWrittenForm() throws {
        let expected = ["Searched", "Searcher", "Searching"]

        #expect(try Self.found("name:/^Search/ kind:struct|enum|class") == expected)
        #expect(try Self.found("name:/^Search/ kind:struct|kind:enum|kind:class") == expected)
        #expect(try Self.found("name:/^Search/ kind:struct|kind:enum|class") == expected)
    }

    /// A negated alternation excludes every alternative, as a negated `name:` one does.
    @Test
    func aNegatedAlternationExcludesBoth() throws {
        #expect(try Self.found("name:/^Search/ !kind:struct|enum") == ["Searchable", "Searched"])
    }

    // MARK: Alternation on the other fields

    /// Each field reads one alternative exactly as it reads a single value, and the term matches when any does.
    @Test
    func everyFieldReadsAlternatives() throws {
        #expect(try Self.found("kind:func modifier:private|static") == ["Searched.closed", "Shelf.emptied"])
        #expect(try Self.found("kind:func effect:async|throws") == ["Searched.closed"])
        #expect(try Self.found("inherits:Hashable|Equatable") == ["Depot"])
        #expect(try Self.found("owner:Searcher|Shelf kind:func") == ["Searcher.Skipped", "Searcher.skipped", "Shelf.emptied"])
        #expect(try Self.found("kind:func calls:restock|missing") == ["Depot.skipped", "Searcher.skipped"])
        #expect(try Self.found("kind:func uses:missing|restock") == ["Depot.skipped", "Searcher.skipped"])
        #expect(try Self.found("kind:func sig:[Shelf]|[String]") == ["Depot.labels", "Depot.shelves"])
        #expect(try Self.found("kind:func has:await|closure") == [])
        #expect(try Self.found("imports:Missing|Foundation kind:enum") == ["Searching"])
        #expect(try Self.found("kind:func path:Tally|Missing name:closed") == ["Searched.closed"])
    }

    /// An alternative a field would refuse on its own is refused inside the alternation.
    @Test
    func anAlternativeTheFieldRefusesIsRefused() {
        #expect(Self.refusal("kind:struct|unicorn").contains("unknown kind \"unicorn\""))
        #expect(Self.refusal("effect:async|rethrows").contains("unknown effect \"rethrows\""))
        #expect(Self.refusal("has:await|unicorn").contains("unknown shape \"unicorn\""))
    }

    /// The repeated-prefix spelling and the kind word `function` are read as the grammar's own, and the answer says so.
    @Test
    func theReadingIsSaid() throws {
        let repeated = try StructuralQuery("kind:struct|kind:enum")
        let word = try StructuralQuery("kind:function|enum")

        #expect(repeated.source == "kind:struct|enum")
        #expect(repeated.readingNote == "read kind:struct|kind:enum as kind:struct|enum — the spelling search takes.")
        #expect(word.source == "kind:func|enum")
    }

    /// The echo line says an alternation or a regex was read as one, for any field.
    @Test
    func theEchoNamesTheReading() throws {
        #expect(try Self.echo("kind:struct|enum") == "search kind:struct|enum — kind: any of struct, enum")
        #expect(try Self.echo("!owner:Depot|Shelf") == "search !owner:Depot|Shelf — !owner: any of Depot, Shelf")
        #expect(try Self.echo("path:/Tally/") == "search path:/Tally/ — path: a case-insensitive regex")
    }

    // MARK: Guards

    /// A field that cannot take a regex still refuses one, with the wording it always had.
    @Test
    func aRegexOnAFieldThatCannotTakeOneIsStillRefused() {
        for value in ["calls:/x/", "uses:/x/", "kind:/x/", "owner:/x/", "attr:/x/"] {
            #expect(Self.refusal(value).contains("uses a /regex/, which search does not read as a pattern"), "\(value)")
        }

        #expect(Self.refusal("calls:/x/").contains("calls: matches the value exactly"))
    }

    /// A regex holding a `|` on a field that cannot take one is refused whole, not split into alternatives.
    @Test
    func aRegexWithAlternationOnAFieldThatCannotTakeOneIsRefused() {
        for value in ["owner:/a|b/", "!calls:/a|b/", "kind:/struct|enum/", "has:/try|await/", "attr:/Test|Suite/", "imports:/Foundation|Testing/"] {
            #expect(Self.refusal(value).contains("uses a /regex/"), "\(value)")
        }
    }

    /// A plain `path:` or `sig:` value is the case-sensitive substring it was.
    @Test
    func aPlainSubstringStillMatchesAsBefore() throws {
        #expect(try Self.found("kind:struct path:Sources/App") == ["Depot", "Searcher"])
        #expect(try Self.found("kind:struct path:sources/app") == [])
        #expect(try Self.found("kind:func sig:shelf") == [])
        #expect(try Self.found("kind:func sig:Shelf") == ["Depot.shelves"])
    }

    /// A regex that repeats a group or does not compile is refused on `path:` and `sig:` as on `name:`, naming the field.
    @Test
    func anUnreadableRegexIsRefusedNamingItsField() {
        #expect(Self.refusal("path:/(ab)+/").contains("\"path:/(ab)+/\" is not read as a regex"))
        #expect(Self.refusal("sig:/[/").contains("\"sig:/[/\" does not compile"))
    }

    /// An operator spelt with `|` stays one literal value, on a field that would split an alternation.
    @Test
    func anOperatorNameIsNotSplit() throws {
        let query = try StructuralQuery("sig:||")

        #expect(query.readingNote == nil)
        #expect(try Self.echo("sig:||") == "search sig:||")
    }
}

private extension SearchAlternationTests {
    /// One fixture file: where it sits and what it says.
    struct SourceFile {
        let path: String
        let text: String
    }
}
