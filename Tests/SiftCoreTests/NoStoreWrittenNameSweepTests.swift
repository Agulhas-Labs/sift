//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` sweep in a worktree with no index store answers an associated type, and an extension of a type the tree does not declare, with the lines writing the name rather than an UNAVAILABLE line, and says nothing about a store for a name declared nowhere.
@Suite(.temporaryDirectories)
struct NoStoreWrittenNameSweepTests {
    private static func makeWorktree(named name: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("protocol Probe {\n    associatedtype Reading\n}\n\nextension URL {\n    var label: String { path }\n}\n", to: "Sources/App/Probe.swift", in: root)
        try TestSources.write("func sample<P: Probe>(_ probe: P) -> P.Reading.Type { P.Reading.self }\nlet home = URL(fileURLWithPath: \"/\")\n", to: "Sources/App/Sample.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return try TestSources.makeWorktree(of: root, named: name)
    }

    private static func answer(_ symbol: String, in directory: URL, references: Bool = true) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: references))
    }

    /// A plain `where` stands in with the same lines, since the uses a store would list are what it is asked for too.
    @Test
    func aPlainLookupOfAnAssociatedTypeListsTheLinesWritingItsName() async throws {
        let output = try await Self.answer("Probe.Reading", in: Self.makeWorktree(named: "agent-9d8c7b6a"), references: false)

        #expect(output.contains("used by: NOT ANSWERED from the index store"), "\(output)")
        #expect(output.contains("func sample<P: Probe>(_ probe: P) -> P.Reading.Type"), "\(output)")
    }

    @Test
    func anAssociatedTypeIsSweptByTheLinesWritingItsName() async throws {
        let output = try await Self.answer("Probe.Reading", in: Self.makeWorktree(named: "agent-1f2e3d4c"))

        #expect(output.contains("no index store in this worktree"), "\(output)")
        #expect(output.contains("references: all sites by written name, paged by file"), "\(output)")
        #expect(!output.contains("references: UNAVAILABLE"), "\(output)")
        #expect(output.contains("used by: NOT ANSWERED from the index store"), "\(output)")
        #expect(output.contains(":1  | func sample<P: Probe>(_ probe: P) -> P.Reading.Type { P.Reading.self }"), "\(output)")
    }

    /// The extension's own lines are uses of the type it extends, since the tree declares no type of the name to own them.
    @Test
    func anExtensionOfATypeTheTreeDoesNotDeclareIsSweptByEveryLineWritingIt() async throws {
        let output = try await Self.answer("URL", in: Self.makeWorktree(named: "agent-5b6a7988"))

        #expect(output.contains("references: all sites by written name, paged by file"), "\(output)")
        #expect(!output.contains("references: UNAVAILABLE"), "\(output)")
        #expect(output.contains(":5  | extension URL {"), "\(output)")
        #expect(output.contains(":2  | let home = URL(fileURLWithPath: \"/\")"), "\(output)")
    }

    /// A store would not turn the miss into an answer, so the answer does not blame its absence.
    @Test
    func aNameDeclaredNowhereGetsNoReferencesLine() async throws {
        let output = try await Self.answer("Gauge", in: Self.makeWorktree(named: "agent-0a1b2c3d"))

        #expect(output.contains("no declarations found"), "\(output)")
        #expect(!output.contains("references:"), "\(output)")
    }
}
