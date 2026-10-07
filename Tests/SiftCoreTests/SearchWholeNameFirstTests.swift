//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the order `search` lists a `name:` pattern's matches in: the declarations whose whole name it matches first, then those it matches only in part, every row kept.
///
/// Short alternatives turn up inside many longer names, so in path order the declarations a caller named sit anywhere in a long answer, often past its first page.
@Suite(.temporaryDirectories)
struct SearchWholeNameFirstTests {
    /// Declarations holding the words `key` and `save` only in part, in the file whose path sorts first.
    private static var depot: String {
        """
        struct Depot {
            enum Keys { case first }
            func monkey() {}
            func saved() {}
        }
        """
    }

    /// Declarations named `key` and `save` exactly, in the file whose path sorts last.
    private static var shelf: String {
        """
        struct Shelf {
            static func key(of path: String) -> String { path }
            func save(listing: Int) {}
        }
        """
    }

    /// Runs `query` over both fixtures written to disk, the way `search` reads a tree, and renders the answer from `offset`.
    private static func rendered(_ query: String, offset: Int = 0) async throws -> String {
        let tree = try await run(query)
        return SearchRenderer.render(result: tree.result, query: tree.query, offset: offset)
    }

    /// Runs `query` over both fixtures and returns the result with the parsed query, unrendered.
    private static func run(_ query: String) async throws -> (result: StructuralSearch.Result, query: StructuralQuery) {
        let root = try TemporaryDirectory.make("search-whole-name")
        let files = ["Sources/App/Alpha.swift": depot, "Sources/App/Zeta.swift": shelf]
        for (path, source) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
        let enumerator = FileEnumerator(repoRoot: root, config: SiftConfig(), gitListing: { files.keys.sorted() })
        let parsed = try StructuralQuery(query)
        let result = await StructuralSearch(repoRoot: root, enumerator: enumerator).run(parsed)
        return (result, parsed)
    }

    /// The qualified names an answer lists, in the order it lists them.
    private static func listed(_ answer: String) -> [String] {
        answer.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  :") else { return nil }
            return line.split(separator: " ", maxSplits: 4)[1].description
        }
    }

    /// An alternation lists the names it matches whole ahead of those it matches in part, though their file sorts last.
    @Test
    func anAlternationListsWholeNameMatchesFirst() async throws {
        let answer = try await Self.rendered("name:key|save")

        #expect(Self.listed(answer) == ["Shelf.key(of:)", "Shelf.save(listing:)", "Depot.Keys", "Depot.monkey()", "Depot.saved()"])
    }

    /// A regex leads with the names it matches from start to end, its argument list aside.
    @Test
    func aRegexListsWholeNameMatchesFirst() async throws {
        let answer = try await Self.rendered("name:/key|save/")

        #expect(Self.listed(answer) == ["Shelf.key(of:)", "Shelf.save(listing:)", "Depot.Keys", "Depot.monkey()", "Depot.saved()"])
    }

    /// The summary line says how many lead for matching whole; no line marks where the partial matches begin.
    @Test
    func theAnswerSaysWhichRowsMatchedWhole() async throws {
        let answer = try await Self.rendered("name:key|save")
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[1] == "5 declaration(s) in 2 file(s) — scanned 2 file(s); the 2 whose whole name matches come first")
        #expect(!answer.contains("only in part"))
        let zeta = try #require(lines.firstIndex(of: "Sources/App/Zeta.swift:"))
        let alpha = try #require(lines.firstIndex(of: "Sources/App/Alpha.swift:"))
        #expect(zeta < alpha)
    }

    /// Paging leaves the clause as it was, once, whether the page starts inside the whole matches, on the boundary or past it.
    @Test
    func theClauseIsStableAcrossPages() async throws {
        let clause = "; the 2 whose whole name matches come first"
        for offset in [0, 1, 2, 3, 4] {
            let answer = try await Self.rendered("name:key|save", offset: offset)

            #expect(answer.components(separatedBy: clause).count == 2, "offset \(offset)")
            #expect(!answer.contains("only in part"), "offset \(offset)")
        }
    }

    /// With no whole match, or only whole matches, the answer is byte for byte the plain path-ordered one the pattern read as a substring gives.
    @Test
    func oneGroupOnlyAnswersAsThePlainPathDoes() async throws {
        for query in ["name:/eys|onke|aved/", "name:key|save kind:func path:Zeta"] {
            let tree = try await Self.run(query)
            let plain = StructuralSearch.Result(matches: tree.result.matches.sorted { ($0.path, $0.line) < ($1.path, $1.line) }, filesScanned: tree.result.filesScanned, eliminations: tree.result.eliminations)

            #expect(tree.result.matches.map(\.qualifiedName) == plain.matches.map(\.qualifiedName), "\(query)")
            #expect(SearchRenderer.render(result: tree.result, query: tree.query) == SearchRenderer.render(result: plain, query: tree.query), "\(query)")
            #expect(SearchRenderer.renderCount(result: tree.result, query: tree.query, moduleFor: { _ in "App" }) == SearchRenderer.renderCount(result: plain, query: tree.query, moduleFor: { _ in "App" }), "\(query)")
        }
    }

    /// `--count` carries the clause the way the listing does.
    @Test
    func countCarriesTheClause() async throws {
        let tree = try await Self.run("name:key|save")
        let counted = SearchRenderer.renderCount(result: tree.result, query: tree.query, moduleFor: { _ in "App" })

        #expect(counted.contains("5 declaration(s) in 2 file(s) — scanned 2 file(s); the 2 whose whole name matches come first"))
    }

    /// A single bare word keeps path-then-line order and an unchanged summary line.
    @Test
    func aSingleWordKeepsPathOrder() async throws {
        let answer = try await Self.rendered("name:save")

        #expect(Self.listed(answer) == ["Depot.saved()", "Shelf.save(listing:)"])
        #expect(answer.contains("2 declaration(s) in 2 file(s) — scanned 2 file(s)\n"))
    }

    /// Where every match is whole there is no order to explain, so the summary line is unchanged.
    @Test
    func allWholeMatchesAddNothing() async throws {
        let answer = try await Self.rendered("name:key|save kind:func path:Zeta")

        #expect(Self.listed(answer) == ["Shelf.key(of:)", "Shelf.save(listing:)"])
        #expect(answer.contains("2 declaration(s) in 1 file(s) — scanned 1 file(s)\n"))
    }
}
