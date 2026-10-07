//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` sweep with no index store pages its name-matched sites by file on the offset cursor, so a large sweep stays a bounded answer and nothing it holds is left unreachable.
@Suite(.temporaryDirectories)
struct NoStoreSweepPagingTests {
    /// More files than one page lists, each calling `relay()` and building `Point`, a struct declaring no init.
    private static let callerCount = WhereRenderer.listCap + 9
    /// Calls of `Point()` written in one file beside the one each caller makes, so the sweep holds 300 of them.
    private static let extraPointCalls = 300 - callerCount
    /// Files calling `pulse()` from as many functions each, so a page fills its byte budget before its file cap.
    private static let denseCount = 30
    private static let callsPerDenseFile = 60

    private static func makeWorktree(named name: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func relay() {}\nfunc pulse() {}\nstruct Point {}\n", to: "Sources/App/Relay.swift", in: root)
        try TestSources.write("struct Left { func run() {} }\nstruct Right { func run() {} }\n", to: "Sources/App/Owners.swift", in: root)
        for index in 1 ... callerCount {
            try TestSources.write("func call\(index)() { relay(); _ = Point(); Left().run() }\n", to: "Sources/App/Caller\(index).swift", in: root)
        }
        let points = (1 ... extraPointCalls).map { "let point\($0) = Point()" }.joined(separator: "\n")
        try TestSources.write(points + "\n", to: "Sources/App/Points.swift", in: root)
        for file in 1 ... denseCount {
            let bodies = (1 ... callsPerDenseFile).map { "func dense\(file)x\($0)() { pulse() }" }.joined(separator: "\n")
            try TestSources.write(bodies + "\n", to: "Sources/Dense/Dense\(file).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        return try TestSources.makeWorktree(of: root, named: name)
    }

    private static func answer(_ symbol: String, in directory: URL, refs: Bool = true, offset: Int = 0, syntactic: Bool = false) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        let options = WhereOptions(includeSemantic: !syntactic, includeReferences: refs, offset: offset, nameMatchedSiteCap: 5)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: options)
    }

    /// The offset a page's truncation line hands on, or `nil` where the page is the last.
    private static func nextOffset(in output: String) -> Int? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("truncated:") && $0.contains("pass offset") }),
              let cursor = line.components(separatedBy: "pass offset ").last?.split(separator: " ").first
        else { return nil }
        return Int(cursor)
    }

    @Test
    func aCallSiteSweepPagesByFileAndTheCursorReachesEveryFile() async throws {
        let worktree = try Self.makeWorktree(named: "agent-0a1b2c3d")
        let first = try await Self.answer("relay()", in: worktree)
        let next = try #require(Self.nextOffset(in: first), "\(first)")
        let second = try await Self.answer("relay()", in: worktree, offset: next)

        #expect(first.contains("truncated: \(Self.callerCount - WhereRenderer.listCap) more files — pass offset \(WhereRenderer.listCap) to continue"), "\(first)")
        #expect(second.contains("(…\(WhereRenderer.listCap) files skipped)"), "\(second)")
        #expect(Self.nextOffset(in: second) == nil, "\(second)")
        for index in 1 ... Self.callerCount {
            let file = "Sources/App/Caller\(index).swift:"
            #expect(first.contains(file) != second.contains(file), "caller \(index) should be on exactly one page")
        }
        #expect(first.utf8.count < 10000, "\(first.utf8.count) bytes")
    }

    @Test
    func aPageStopsAtItsByteBudgetBeforeItsFileCap() async throws {
        let worktree = try Self.makeWorktree(named: "agent-4e5f6a7b")
        let first = try await Self.answer("pulse()", in: worktree)
        let next = try #require(Self.nextOffset(in: first), "\(first)")
        let listed = (1 ... Self.denseCount).count { first.contains("Sources/Dense/Dense\($0).swift:") }

        #expect(next == listed, "\(first)")
        #expect(next < Self.denseCount, "\(first)")
        #expect(first.utf8.count < 10000, "\(first.utf8.count) bytes")
        // A file's lines are never cut: every call in a listed file is on the page.
        #expect(first.components(separatedBy: "  in dense").count - 1 == listed * Self.callsPerDenseFile, "\(first)")
    }

    /// A `T.init` of a struct declaring no init resolves no declaration, and is swept and paged all the same rather than answered UNAVAILABLE and cut to a sample.
    @Test
    func anUndeclaredInitializerIsSweptAndPaged() async throws {
        let worktree = try Self.makeWorktree(named: "agent-8c9d0e1f")
        let first = try await Self.answer("Point.init", in: worktree)
        var pages = [first]
        while pages.count < 5, let next = Self.nextOffset(in: pages[pages.count - 1]) {
            try await pages.append(Self.answer("Point.init", in: worktree, offset: next))
        }

        #expect(pages.count > 1, "\(first)")
        #expect(first.contains("references: all sites by written name, paged by file"), "\(first)")
        #expect(!first.contains("references: UNAVAILABLE"), "\(first)")
        #expect(!first.contains("more call sites"), "\(first)")
        #expect(first.contains("\"Point.init\" (300 call sites in \(Self.callerCount + 1) files)"), "\(first)")
        let files = (1 ... Self.callerCount).map { "Sources/App/Caller\($0).swift:" } + ["Sources/App/Points.swift:"]
        for file in files {
            #expect(pages.count { $0.contains(file) } == 1, "\(file) should be on exactly one page")
        }
    }

    /// A cursor past the last file says how many it skipped rather than serving the first page again.
    @Test
    func anOffsetPastTheEndSaysItSkippedEveryFile() async throws {
        let worktree = try Self.makeWorktree(named: "agent-2a3b4c5d")
        let output = try await Self.answer("relay()", in: worktree, offset: 500)

        #expect(output.contains("(…\(Self.callerCount) files skipped)"), "\(output)")
        #expect(!output.contains("Sources/App/Caller1.swift:"), "\(output)")
    }

    /// An offset nothing in the answer pages is named as unused, never served as though it had paged.
    @Test
    func anOffsetNothingPagesIsNamedUnused() async throws {
        let worktree = try Self.makeWorktree(named: "agent-6e7f8a9b")
        let withoutRefs = try await Self.answer("relay()", in: worktree, refs: false, offset: 40)
        let syntactic = try await Self.answer("relay()", in: worktree, offset: 40, syntactic: true)
        let paged = try await Self.answer("relay()", in: worktree, offset: 40)

        #expect(withoutRefs.contains("(offset 40 unused"), "\(withoutRefs)")
        #expect(syntactic.contains("references: UNAVAILABLE"), "\(syntactic)")
        #expect(syntactic.contains("(offset 40 unused"), "\(syntactic)")
        #expect(!paged.contains("unused"), "\(paged)")
    }

    /// A bare name two unrelated owners declare, swept past one page, names the query that narrows it to one owner; one that fits on a page does not.
    @Test
    func aSeveralOwnersSweepPastOnePageNamesTheNarrowingQuery() async throws {
        let worktree = try Self.makeWorktree(named: "agent-0c1d2e3f")
        let output = try await Self.answer("run()", in: worktree)
        let single = try await Self.answer("relay()", in: worktree)

        #expect(output.contains("references: 2 unrelated owners declare \"run()\""), "\(output)")
        #expect(output.contains("`where Left.run() --refs`") || output.contains("`where Right.run() --refs`"), "\(output)")
        #expect(!single.contains("unrelated owners"), "\(single)")
    }

    /// The sweep answers references after all, so the mode line never says they do not answer, and the sweep line says only a typealias use no type's block folded in may be missing.
    @Test
    func theModeLineAndTheSweepLineAgree() async throws {
        let worktree = try Self.makeWorktree(named: "agent-4a5b6c7d")
        let output = try await Self.answer("relay()", in: worktree)
        let mode = try #require(output.split(separator: "\n").first { $0.hasPrefix("mode:") })

        #expect(!mode.contains("references do not"), "\(mode)")
        #expect(!mode.contains(SiftEngine.syntaxOnlyTail), "\(mode)")
        #expect(output.contains("may miss protocol, closure, unfolded-typealias uses"), "\(output)")
        #expect(!output.contains("(a typealias, a protocol, a closure) is not among them"), "\(output)")
    }
}
