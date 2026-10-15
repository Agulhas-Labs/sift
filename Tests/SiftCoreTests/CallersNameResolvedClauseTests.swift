//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A store-backed `callers of` heading says its sites are resolved to this one declaration when other types declare the same base name, so a reader need not grep the bare name to rule them out; the name-matched path, whose sites are not resolved, never says it.
@Suite(.temporaryDirectories)
struct CallersNameResolvedClauseTests {
    static var twoTypes: String {
        """
        struct A { func f() {} }
        struct B { func f() {} }
        func callNotes(_ a: A) { a.f() }
        func callsHelper(_ b: B) { b.f() }
        """
    }

    static var unique: String {
        """
        struct A { func f() {} }
        func callNotes(_ a: A) { a.f() }
        """
    }

    static func answer(_ symbol: String, source: String, built: Bool = true) async throws -> String {
        let root = try WhereStoreWrapperSitesTests.repo(["Sources/Probe/Probe.swift": source])
        if built {
            return try await WhereStoreWrapperSitesTests.lookup([symbol], in: root)[0]
        }
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    @Test
    func aSharedBaseNameIsCountedOnTheCallersHeading() async throws {
        let output = try await Self.answer("A.f", source: Self.twoTypes)

        #expect(output.contains("callers of Probe.A.f() (1, resolved to this declaration — f is declared 1 time on other types, not counted here; where f lists them):"), "\(output)")
    }

    @Test
    func aBareNameQueryCarriesNoSelfPointer() async throws {
        // Related owners keep a bare name answerable, so each declaration gets a callers heading of its own.
        let source = """
        class Base { func f() {} }
        class Sub: Base { override func f() {} }
        func callNotes(_ base: Base) { base.f() }
        func callsHelper(_ sub: Sub) { sub.f() }
        """
        let bare = try await Self.answer("f", source: source)
        let narrowed = try await Self.answer("Base.f", source: source)

        #expect(bare.contains("f is declared 1 time on other types, not counted here)"), "\(bare)")
        #expect(!bare.contains("where f lists them"), "\(bare)")
        #expect(narrowed.contains("not counted here; where f lists them)"), "\(narrowed)")
    }

    @Test
    func aHedgeIsJoinedToTheClauseWithASemicolon() async throws {
        let source = """
        protocol P { func f() }
        struct A: P { func f() {} }
        struct B { func f() {} }
        func callNotes(_ p: some P, _ a: A) { p.f(); a.f() }
        """
        let output = try await Self.answer("A.f", source: source)

        #expect(output.contains("; resolved to this declaration — f is declared"), "\(output)")
        #expect(!output.contains(", resolved to this declaration"), "\(output)")
    }

    @Test
    func aUniqueNameCarriesNoClause() async throws {
        let output = try await Self.answer("A.f", source: Self.unique)

        #expect(output.contains("callers of Probe.A.f() (1):"), "\(output)")
        #expect(!output.contains("resolved to this declaration"), "\(output)")
    }

    @Test
    func theNameMatchedPathCarriesNoClause() async throws {
        let output = try await Self.answer("A.f", source: Self.twoTypes, built: false)

        #expect(!output.contains("resolved to this declaration"), "\(output)")
    }

    @Test
    func theNonCodeHeadingHasNoStrayApostrophe() {
        let mentions = NonCodeMentions(files: [NonCodeMentions.File(path: "A.swift", isMarkdown: false, lines: [NonCodeMentions.Line(number: 1, kind: .comment)], codeLines: 0)], fileNames: [], swiftFilesRead: 1, markdownFilesRead: 0)
        let header = WhereNonCodeSection(mentions: mentions, isAmbiguous: true).header

        #expect(header.contains("may include same-named symbols —"), "\(header)")
        #expect(!header.contains("symbols'"), "\(header)")
    }
}
