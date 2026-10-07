//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A rename or delete sweep asked in a tree with no index store answers with every name-matched site, saying it is syntactic only, rather than a sample and an instruction to grep.
@Suite(.temporaryDirectories)
struct WorktreeSyntacticSweepTests {
    /// Call sites of `relay()`, one per file, lines writing `Gauge` in one file, and files writing it once: each more than the shell's cap on name-matched sites, the per-file cap on a type's lines, and the cap on its files.
    private static let callerCount = 8
    private static let gaugeLineCount = WhereRenderer.lineListCap + 5
    private static let panelCount = WhereRenderer.listCap + 1

    /// The command line's cap on name-matched sites, which a sweep must not apply.
    private static let shellOptions = WhereOptions(includeReferences: true, nameMatchedSiteCap: 5)

    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func relay() {}\nstruct Gauge {}\n", to: "Sources/App/Relay.swift", in: root)
        for index in 1 ... callerCount {
            try TestSources.write("func call\(index)() { relay() }\n", to: "Sources/App/Caller\(index).swift", in: root)
        }
        let gauges = (1 ... gaugeLineCount).map { "let gauge\($0) = Gauge()" }.joined(separator: "\n")
        try TestSources.write(gauges + "\n", to: "Sources/App/Gauges.swift", in: root)
        for index in 1 ... panelCount {
            try TestSources.write("let panel\(index) = Gauge()\n", to: "Sources/App/Panel\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }

    private static func answer(_ symbol: String, in directory: URL, options: WhereOptions = shellOptions) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: options)
    }

    @Test
    func aWorktreeSweepSaysItIsSyntacticAndListsEveryCallSite() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(), named: "agent-5e6f7a8b")
        let output = try await Self.answer("relay()", in: worktree)
        let lines = output.split(separator: "\n").map(String.init)

        #expect(lines.contains { $0.hasPrefix("references: all sites by written name, paged by file") }, "\(output)")
        #expect(output.contains("no index store in this worktree"), "\(output)")
        #expect(!output.contains("references: UNAVAILABLE"), "\(output)")
        #expect(!output.contains("truncated:"), "\(output)")
        for index in 1 ... Self.callerCount {
            #expect(output.contains("Sources/App/Caller\(index).swift"), "caller \(index) missing:\n\(output)")
        }
    }

    /// Every line of a file is listed, and the files past one page are reached through the cursor its truncation line hands on.
    @Test
    func aWorktreeSweepOfATypeListsEveryLineItIsWrittenOn() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(), named: "agent-9c0d1e2f")
        let output = try await Self.answer("Gauge", in: worktree)
        let row = try #require(output.split(separator: "\n").first { $0.contains("Sources/App/Gauges.swift (") }, "\(output)")
        let truncation = try #require(output.split(separator: "\n").first { $0.contains("truncated:") }, "\(output)")
        let next = try #require(truncation.components(separatedBy: "pass offset ").last?.split(separator: " ").first.flatMap { Int($0) }, "\(truncation)")
        var options = Self.shellOptions
        options.offset = next
        let rest = try await Self.answer("Gauge", in: worktree, options: options)

        #expect(row.hasSuffix(": " + (1 ... Self.gaugeLineCount).map(String.init).joined(separator: ", ")), "\(row)")
        #expect(!output.contains("past the per-file cap"), "\(output)")
        #expect(truncation.hasSuffix("— pass offset \(next) to continue"), "\(truncation)")
        #expect(!rest.contains("truncated:"), "\(rest)")
        for index in 1 ... Self.panelCount {
            let file = "Sources/App/Panel\(index).swift (1): 1"
            #expect(output.contains(file) != rest.contains(file), "panel \(index) should be on exactly one page")
        }
    }

    /// A checkout never built has no store either, and its mode line names the tree rather than claiming a worktree.
    @Test
    func aCheckoutSweepWithNoStoreNamesTheTreeNotAWorktree() async throws {
        let output = try await Self.answer("relay()", in: Self.makeRepo())

        #expect(output.split(separator: "\n").contains { $0.hasPrefix("references: all sites by written name, paged by file") }, "\(output)")
        #expect(output.contains("no index store for this tree yet"), "\(output)")
        #expect(!output.contains("in this worktree"), "\(output)")
    }

    /// Without `--refs` nothing is swept, so the shell's sample of name-matched sites stays a sample.
    @Test
    func withoutRefsTheShellCapStillHolds() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(), named: "agent-3a4b5c6d")
        let output = try await Self.answer("relay()", in: worktree, options: WhereOptions(nameMatchedSiteCap: 5))

        #expect(output.contains("truncated: 3 more"), "\(output)")
        #expect(!output.contains("references: all sites by written name, paged by file"), "\(output)")
    }
}
