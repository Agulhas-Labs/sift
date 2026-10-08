//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how a query's text is read into terms: each alternative of an `a|b` value read exactly as its field reads one value, a `/…/` value read as a regex whatever its body, and a regex holding a space kept as one term.
///
/// Every reading here either answers the question asked or is refused naming the part it could not read; none is a literal that silently matches nothing.
struct SearchQueryParsingTests {
    /// Three files in different places, so a path term has something to tell apart, with calls and signatures to match — some of them argument labels spelt like field words.
    private static let tree: [SourceFile] = [
        SourceFile(path: "Sources/App/Tally.swift", text: """
        struct Searcher {
            func skipped() { restock() }
        }

        enum Searching {
            case idle
        }

        class Searched {
            static func closed() async throws {}
        }
        """),
        SourceFile(path: "Sources/App/Other.swift", text: """
        struct Depot {
            func skipped() { restock() }
            func shelves() -> [Shelf] { [] }
        }
        """),
        SourceFile(path: "Sources/Kit/Store.swift", text: """
        class Store {
            func load(file: String) {}
            func save(to: String, in: String) {}
            func rename(name: String) {}
            func move(path: String) {}
        }
        """),
    ]

    /// The qualified names `query` finds across the fixture files, each file read only when the query's path terms admit it.
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

    // MARK: Alternatives

    /// A field spelling repeated on each alternative is read as the field it spells on every one, not only the first.
    @Test(arguments: ["file", "in"])
    func aRepeatedFieldSpellingIsReadOnEveryAlternative(spelling: String) throws {
        let query = try StructuralQuery("\(spelling):Tally|\(spelling):Other")

        #expect(query.source == "path:Tally|Other")
        #expect(query.readingNote == "read \(spelling):Tally|\(spelling):Other as path:Tally|Other (a path substring, not a type) — the spelling search takes.")
        #expect(try Self.found("kind:struct \(spelling):Tally|\(spelling):Other") == ["Depot", "Searcher"])
    }

    /// An alternative labelled with another field is refused, naming it, rather than kept as a literal value of the first field.
    @Test
    func anAlternativeNamingAnotherFieldIsRefused() {
        let message = Self.refusal("owner:Searcher|name:closed")

        #expect(message.contains("\"owner:Searcher|name:closed\" has the alternative \"name:closed\", which names another field"))
        #expect(message.contains("write both terms, space-separated"))
    }

    /// An alternative negated on its own is refused: a `!` negates the whole term.
    @Test
    func anAlternativeNegatedOnItsOwnIsRefused() {
        #expect(Self.refusal("kind:struct|!kind:enum").contains("negates the alternative \"!kind:enum\" on its own"))
    }

    /// A field word followed by nothing is part of a `sig:` value — an argument label — not a label of its own.
    @Test
    func aBareLabelInASignatureValueIsPartOfTheValue() throws {
        let query = try StructuralQuery("sig:url:|path:")

        #expect(query.terms.first?.alternatives == ["url:", "path:"])
    }

    /// Two regexes, each labelled, are read as one regex alternating them, and the answer says how it was read.
    @Test
    func labelledRegexAlternativesAreReadAsOneRegex() throws {
        let query = try StructuralQuery("path:/Tally/|path:/Other/")

        #expect(query.source == "path:/Tally|Other/")
        #expect(query.readingNote == "read path:/Tally/|path:/Other/ as path:/Tally|Other/ — the spelling search takes.")
        #expect(try Self.found("kind:struct path:/tally/|path:/other/") == ["Depot", "Searcher"])
    }

    /// A regex alternative beside a plain one is refused: the two match differently, so no one reading is the one meant.
    @Test
    func aRegexBesidePlainAlternativesIsRefused() {
        let message = Self.refusal("path:/Tally/|Other")

        #expect(message.contains("\"path:/Tally/|Other\" mixes a /regex/ alternative with a plain one (Other)"))
        #expect(message.contains("path:/a|b/"))
    }

    /// A regex alternative on a field that reads none is refused as the value alone would be, not split into plain pieces.
    @Test
    func aRegexAlternativeOnAFieldThatReadsNoneIsRefused() {
        #expect(Self.refusal("owner:Depot|owner:/a|b/").contains("uses a /regex/"))
    }

    /// A call spelt with parentheses is read down to its base name inside an alternation, as it is alone.
    @Test
    func aParenthesizedCalleeIsReadInsideAnAlternation() throws {
        let query = try StructuralQuery("calls:missing|restock()")

        #expect(query.source == "calls:missing|restock")
        #expect(query.readingNote == "read calls:missing|restock() as calls:missing|restock — the spelling search takes.")
        #expect(try Self.found("kind:func calls:missing|restock()") == ["Depot.skipped", "Searcher.skipped"])
    }

    /// An alternative that drops argument labels widens the answer, and the sentence names the base it now matches by.
    @Test
    func aLabelledCalleeInsideAnAlternationSaysItWidens() throws {
        let query = try StructuralQuery("calls:missing|restock(from:)")

        #expect(query.source == "calls:missing|restock")
        #expect(query.readingNote == "read calls:missing|restock(from:) as calls:missing|restock — labels are not indexed, so this matches every call named restock, whatever its labels.")
    }

    /// An argument label in a `sig:` value is signature text, even when it is a field word, inside a regex or out.
    @Test(arguments: [
        ("sig:/file:|in:/", ["Store.load", "Store.save"]),
        ("sig:/to:|name:/", ["Store.rename", "Store.save"]),
        ("sig:(path:|name:)", ["Store.move"]),
    ])
    func aFieldWordInASignatureValueIsSignatureText(query: String, expected: [String]) throws {
        #expect(Self.refusal(query).isEmpty)
        #expect(try Self.found(query) == expected)
    }

    /// Nothing inside a regex that a later part closes is read as a label; a regex left open still has its alternatives read one by one.
    @Test
    func aLabelInsideAClosedRegexIsPartOfTheRegex() throws {
        #expect(try StructuralQuery("path:/Tally|name:x/").source == "path:/Tally|name:x/")
        #expect(try Self.found("kind:struct path:/Tally|name:x/") == ["Searcher"])
        #expect(Self.refusal("path:/Tally|name:x").contains("has the alternative \"name:x\", which names another field"))
    }

    /// Two regexes written one after the other without a repeated label are two alternatives, read as the labelled spelling is.
    @Test
    func unlabelledRegexAlternativesAreReadAsOneRegex() throws {
        #expect(try StructuralQuery("name:/^Search/|/^Dep/").source == "name:/^Search|^Dep/")
        #expect(try Self.found("kind:struct name:/^Search/|/^Dep/") == ["Depot", "Searcher"])
        #expect(try Self.found("kind:struct path:/Tally/|/Other/") == ["Depot", "Searcher"])
    }

    /// A regex alternative that refers back to a group is refused, since joined with another its group number would count across both.
    @Test(arguments: [#"/(s)\1/"#, #"/(?<x>s)\k<x>/"#])
    func aRegexAlternativeReferringBackToAGroupIsRefused(alternative: String) {
        let query = "name:\(alternative)|name:/(e)/"

        #expect(Self.refusal(query).contains("has the alternative \"\(alternative)\", which refers back to a group"))
        #expect(Self.refusal(#"name:/a\\1/|name:/b/"#).isEmpty)
    }

    /// A regex alternative that does not compile alone is refused, rather than joined into a regex that compiles with another meaning.
    @Test(arguments: [#"path:/Tally\/|path:/Other/"#, #"path:/Tally\/|/Other/"#])
    func aRegexAlternativeThatDoesNotCompileIsRefused(query: String) {
        #expect(Self.refusal(query).contains(#"has the alternative "/Tally\/", which does not compile as a regex"#))
    }

    // MARK: Regex values

    /// A `/…/` value whose body is all operator characters is a regex, not an operator's name, and the echo says so.
    @Test(arguments: ["/.*/", "/.+/", "/.?/"])
    func anOperatorCharacterBodyIsARegex(value: String) throws {
        #expect(try Self.found("kind:enum name:\(value)") == ["Searching"])
        #expect(try Self.echo("name:\(value)") == "search name:\(value) — name: a case-insensitive regex")
    }

    /// The same value on a field that reads no regex is refused as a regex, not read as an operator nothing calls.
    @Test
    func anOperatorCharacterRegexOnAFieldThatReadsNoneIsRefused() {
        #expect(Self.refusal("calls:/.*/").contains("\"calls:/.*/\" uses a /regex/"))
    }

    /// A regex holding a space is one term, its whitespace as written, and matches across it.
    @Test
    func aRegexHoldingASpaceIsOneTerm() throws {
        let query = try StructuralQuery("name:/a  b/ kind:func")

        #expect(query.terms.count == 2)
        #expect(query.source == "name:/a  b/ kind:func")
        #expect(try Self.echo("name:/a b/") == "search name:/a b/ — name: a case-insensitive regex")
        #expect(try Self.found("sig:/async throws/") == ["Searched.closed"])
    }

    /// A word that opens a regex never swallows the next term, and with no closer the words stay as they were split.
    @Test
    func anUnclosedRegexDoesNotSwallowATerm() throws {
        #expect(try StructuralQuery("sig:/async kind:func throws/").terms.map(\.field) == [.sig, .kind, .name])
        #expect(try StructuralQuery("path:/Sources kind:struct").source == "path:/Sources kind:struct")
    }

    /// The term's own label, or a spelling of it, inside a regex a later part closes is refused, naming the open regex and both fixes, rather than read as regex text that drops the alternative it starts.
    @Test(arguments: [
        ("name:/^Search|name:/^Sweep/", "name:/^Sweep/", "/^Search"),
        ("path:/Tally|path:Sources/", "path:Sources/", "/Tally"),
        ("path:/a|path:b|path:/c/", "path:b", "/a"),
        ("path:/Tally|file:Other/", "file:Other/", "/Tally"),
        ("sig:/async|sig:throws/", "sig:throws/", "/async"),
    ])
    func theTermsOwnLabelInsideAnOpenRegexIsRefused(query: String, part: String, open: String) {
        let message = Self.refusal(query)
        let field = String(query.prefix { $0 != ":" })

        #expect(message.contains("has the alternative \"\(part)\" inside the regex \"\(open)\", which it leaves open"))
        #expect(message.contains("\(field):/a/|\(field):/b/"))
        #expect(message.contains("\(field):/a|b/"))
    }

    /// Another field's label inside a regex a later part closes stays regex text.
    @Test(arguments: ["sig:/file:|in:/", "path:/Tally|name:x/"])
    func anotherFieldsLabelInsideAnOpenRegexIsRegexText(query: String) throws {
        #expect(try StructuralQuery(query).source == query)
    }

    /// A closed regex beside a plain part, on either side, is refused as mixed rather than split at the regex's own `|` into plain values.
    @Test(arguments: [("path:/a|b/|c", "c"), ("path:c|/a|b/", "c")])
    func aClosedRegexBesideAPlainPartIsRefused(query: String, plain: String) {
        #expect(Self.refusal(query).contains("\"\(query)\" mixes a /regex/ alternative with a plain one (\(plain))"))
    }

    /// A word opening a regex that holds a `|` is refused rather than run on across whitespace to a later closer, since its alternatives could end at either.
    @Test
    func aRegexHoldingABarIsNotRunOnAcrossWhitespace() {
        let message = Self.refusal("path:/Tally|name:x Foo/")

        #expect(message.contains("\"path:/Tally|name:x\" opens a /regex/ holding a | that only the later word \"Foo/\" closes"))
        #expect(message.contains(#"write the space inside the regex as \s"#))
    }

    /// An escaped backslash before a group number still leaves the number a back-reference, so the alternative is refused.
    @Test
    func aBackReferenceAfterAnEscapedBackslashIsRefused() {
        #expect(Self.refusal(#"name:/a\\\1/|name:/b/"#).contains(#"has the alternative "/a\\\1/", which refers back to a group"#))
    }
}

private extension SearchQueryParsingTests {
    /// One fixture file: where it sits and what it says.
    struct SourceFile {
        let path: String
        let text: String
    }
}
