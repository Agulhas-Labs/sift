//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// One offset is one boundary for a whole no-store `--refs` answer: every list in it pages by the same file window, under one continuation, so following that cursor to the end shows every file of every list exactly once.
@Suite(.temporaryDirectories)
struct NoStoreSweepWindowTests {
    /// Files each building the type once by name and once through an implicit `.init`, so two lists of the answer hold every one of them.
    private static let fileCount = 30
    /// Pads each enclosing name, so a page fills its byte budget long before its file cap.
    private static let padding = String(repeating: "_0123456789", count: 12)
    /// More pages than any answer here can take, so a cursor that never advances ends the walk rather than the suite.
    private static let pageLimit = 40

    private static func makeWorktree(named name: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        let declarations = """
        struct Point { var x: Int; var y: Int }
        struct Box { init(size: Int) {} }
        func take(_ point: Point) {}
        func hold(_ box: Box) {}
        func relay() {}

        """
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        // The implicit call the scan cannot tell, spelled apart so the fixture's source is not read as this file's own.
        let implicit = "." + "init"
        for index in 1 ... fileCount {
            let name = String(format: "H%03d", index)
            let body = """
            func build\(name)\(padding)() { _ = Point(x: 1, y: 2); take(\(implicit)(x: 1, y: 2)) }
            func make\(name)\(padding)() { _ = Box(size: 1); hold(\(implicit)(size: 1)) }

            """
            try TestSources.write(body, to: "Sources/App/\(name).swift", in: root)
        }
        // One file whose calls alone run past a page's budget, then one more after it.
        let dense = (1 ... 120).map { "func dense\($0)\(padding)() { relay() }" }.joined(separator: "\n")
        try TestSources.write(dense + "\n", to: "Sources/Relay/A.swift", in: root)
        try TestSources.write("func lone() { relay() }\n", to: "Sources/Relay/B.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return try TestSources.makeWorktree(of: root, named: name)
    }

    private static func answer(_ symbol: String, in directory: URL, offset: Int) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        let options = WhereOptions(includeSemantic: true, includeReferences: true, offset: offset)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: options)
    }

    /// Every page of `symbol`'s sweep, following the continuation from offset 0, and the offsets it was asked at; stops at `pageLimit` or where a cursor fails to advance.
    private static func walk(_ symbol: String, in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (pages: [String], offsets: [Int]) {
        var pages: [String] = []
        var offsets = [0]
        while pages.count < pageLimit {
            let page = try await answer(symbol, in: directory, offset: offsets[offsets.count - 1])
            pages.append(page)
            let continuations = page.split(separator: "\n").filter { $0.contains("pass offset ") }
            #expect(continuations.count <= 1, "one continuation to an answer: \(page)", sourceLocation: sourceLocation)
            guard let line = continuations.first,
                  let cursor = line.components(separatedBy: "pass offset ").last?.split(separator: " ").first.flatMap({ Int($0) })
            else { break }
            guard cursor > offsets[offsets.count - 1] else {
                Issue.record("the cursor did not advance past \(offsets[offsets.count - 1]): \(page)", sourceLocation: sourceLocation)
                break
            }
            offsets.append(cursor)
        }
        return (pages, offsets)
    }

    /// How many times each file is listed under each list heading of `page`, a file counted under the heading last seen above it.
    private static func listings(in page: String, headings: [String: String]) -> [String: [String: Int]] {
        var counts: [String: [String: Int]] = [:]
        var section: String?
        for line in page.split(separator: "\n") {
            if let heading = headings.first(where: { line.contains($0.value) }) {
                section = heading.key
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let section, trimmed.hasPrefix("Sources/App/H"), trimmed.hasSuffix(".swift:") else { continue }
            counts[section, default: [:]][String(trimmed.dropLast()), default: 0] += 1
        }
        return counts
    }

    @Test(arguments: [
        ("Point.init", "\"Point.init\" ("),
        ("Box.init", "\"Box.init\" ("),
    ])
    func everyListOfAnAnswerPagesByOneWindowUnderOneCursor(symbol: String, mainHeading: String) async throws {
        let worktree = try Self.makeWorktree(named: "agent-\(symbol.hasPrefix("Point") ? "1a2b3c4d" : "5e6f7a8b")")
        let (pages, offsets) = try await Self.walk(symbol, in: worktree)
        let headings = ["main": mainHeading, "implicit": "but an implicit .init is called"]
        var seen: [String: [String: Int]] = [:]
        for page in pages {
            for (section, files) in Self.listings(in: page, headings: headings) {
                seen[section, default: [:]].merge(files, uniquingKeysWith: +)
            }
            #expect(!page.contains("\u{E000}"), "a list's slot was left unfilled: \(page)")
        }

        #expect(pages.count > 2, "the sweep should span several pages: \(pages.first ?? "")")
        #expect(!(pages.last ?? "").contains("pass offset"), "\(pages.last ?? "")")
        let files = (1 ... Self.fileCount).map { String(format: "Sources/App/H%03d.swift", $0) }
        for section in headings.keys {
            for file in files {
                #expect(seen[section]?[file] == 1, "\(file) listed \(seen[section]?[file] ?? 0) times under \(section) across offsets \(offsets)")
            }
        }
    }

    /// A single file whose rows alone run past a page's budget is still listed whole, and the cursor moves on past it.
    @Test
    func aFileLargerThanThePageBudgetStillAdvancesTheCursor() async throws {
        let worktree = try Self.makeWorktree(named: "agent-9c0d1e2f")
        let (pages, offsets) = try await Self.walk("relay()", in: worktree)

        #expect(offsets == [0, 1], "\(pages)")
        let first = try #require(pages.first)
        #expect(first.utf8.count > SyntacticSweepPaging.byteBudget, "\(first.utf8.count) bytes")
        #expect(first.contains("Sources/Relay/A.swift:") && !first.contains("Sources/Relay/B.swift:"), "\(first)")
        #expect(pages.count { $0.contains("Sources/Relay/B.swift:") } == 1, "\(pages)")
    }

    /// A list's skip and truncation markers sit at its file headers' indent, in a list nested under another as at the top.
    @Test
    func aPagesMarkersAlignWithItsFileHeaders() async throws {
        let worktree = try Self.makeWorktree(named: "agent-3d4e5f6a")
        let first = try await Self.answer("Point.init", in: worktree, offset: 0)
        let next = try #require(first.split(separator: "\n").first { $0.contains("pass offset ") }?
            .components(separatedBy: "pass offset ").last?.split(separator: " ").first.flatMap { Int($0) })
        let page = try await Self.answer("Point.init", in: worktree, offset: next)
        let lines = page.split(separator: "\n").map(String.init)
        let indent = { (line: String) in line.prefix { $0 == " " }.count }
        // The top list runs to the nested list's heading and the nested list from there to the end; each is checked against its own headers.
        let nested = try #require(lines.firstIndex { $0.contains("but an implicit .init is called") })
        for (range, label) in [(0 ..< nested, "top"), (nested ..< lines.count, "nested")] {
            let list = lines[range]
            let headers = Set(list.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Sources/App/H") }.map(indent))
            let markers = Set(list.filter { $0.contains("files skipped)") || $0.contains("truncated:") }.map(indent))
            #expect(headers.count == 1 && markers == headers, "\(label): headers at \(headers), markers at \(markers)\n\(page)")
        }
    }
}
