//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two pattern forms `name:` reads — an alternation of substrings and a `/…/` regex — and the reply to a pattern that does not compile.
///
/// Callers asking for several names at once write `name:a|b` or `name:/a|b/` first; each form has to answer rather than refuse, or the call goes back to grep.
struct SearchNamePatternTests {
    /// Four methods and an operator whose names the queries below pick apart.
    private static var source: String {
        """
        struct Box {
            func reopen() {}
            func closed() {}
            func finish() {}
            func spin() {}
            static func || (lhs: Box, rhs: Box) -> Bool { true }
        }
        """
    }

    /// The base names of the declarations `query` matches in the fixture, sorted.
    private static func names(_ query: String) throws -> [String] {
        try StructuralMatcher.matches(in: source, path: "Sources/App/Box.swift", query: StructuralQuery(query))
            .map { String($0.qualifiedName.dropFirst("Box.".count).prefix { $0 != "(" }) }
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

    /// `name:a|b` matches a name containing any alternative, each case-insensitively, as a single `name:` substring would.
    @Test
    func alternationMatchesAnyAlternative() throws {
        #expect(try Self.names("name:OPEN|closed kind:func") == ["closed", "reopen"])
    }

    /// A negated alternation keeps only the names that contain none of the alternatives.
    @Test
    func negatedAlternationExcludesEveryAlternative() throws {
        #expect(try Self.names("!name:open|closed kind:func") == ["finish", "spin", "||"])
    }

    /// `name:/…/` is a regular expression over the name: case-insensitive, unanchored, with `|` as its own alternation.
    ///
    /// A `$` ends at a function's base name as well as after its argument list, so either reading of the name answers.
    @Test
    func regexMatchesTheNameCaseInsensitively() throws {
        #expect(try Self.names("name:/^RE|ish$/ kind:func") == ["finish", "reopen"])
        #expect(try Self.names("name:/pi/ kind:func") == ["spin"])
        #expect(try Self.names("name:/n\\(\\)$/ kind:func") == ["reopen", "spin"])
    }

    /// A leading `(?i)` is accepted and changes nothing, since every name pattern already ignores case.
    @Test
    func caseInsensitivePrefixIsRedundant() throws {
        #expect(try Self.names("name:/(?i)OPEN|closed/ kind:func") == ["closed", "reopen"])
        #expect(try Self.names("/(?i)open|closed/ kind:func") == ["closed", "reopen"])
    }

    /// A negated regex keeps only the names it does not match.
    @Test
    func negatedRegexExcludesItsMatches() throws {
        #expect(try Self.names("!name:/^re|ish$/ kind:func") == ["closed", "spin", "||"])
    }

    /// A pattern that does not compile but plainly spells words is read as those words, the regex engine's reason quoted under the header.
    @Test
    func uncompilablePatternIsReadAsTheWordsItSpells() throws {
        let query = try StructuralQuery("name:/(open|closed/ kind:func")

        #expect(query.source == "name:open|closed kind:func")
        #expect(query.readingNote?.contains("expected ')'") == true)
        #expect(query.readingNote?.contains("read name:/(open|closed/ as name:open|closed") == true)
        #expect(try Self.names("name:/(open|closed/ kind:func") == ["closed", "reopen"])
    }

    /// A pattern that does not compile and spells no plain words is refused in one line that quotes the regex engine's reason.
    @Test
    func uncompilablePatternWithNoPlainWordsIsRefusedInOneLine() {
        let message = Self.refusal("name:/[Oo]pen|closed(/")

        #expect(message.contains("does not compile as a regex — expected ')'"))
        #expect(!message.contains("\n"))
    }

    /// A literal name with no pattern in it matches as it always did, an operator's name holding a `|` included.
    @Test
    func literalNameStillMatchesAsASubstring() throws {
        #expect(try Self.names("name:open kind:func") == ["reopen"])
        #expect(try Self.names("name:|| kind:func") == ["||"])
        #expect(try StructuralQuery("name:open").probeName == "open")
    }

    /// The echo line says how a pattern was read, so an alternation is told apart from a literal name holding a `|`.
    @Test
    func echoSaysHowEachPatternWasRead() throws {
        #expect(try Self.echo("name:open|closed kind:func") == "search name:open|closed kind:func — name: any of open, closed")
        #expect(try Self.echo("!name:/^re/") == "search !name:/^re/ — !name: a case-insensitive regex")
        #expect(try Self.echo("name:||") == "search name:||")
    }

    /// Neither pattern form names one declaration, so neither is a name to probe a root by.
    @Test
    func patternsAreNotProbedAsNames() throws {
        #expect(try StructuralQuery("name:open|closed").probeName == nil)
        #expect(try StructuralQuery("name:/open/").probeName == nil)
    }
}
