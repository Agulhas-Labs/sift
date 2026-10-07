//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a declaration whose name is written in backticks: it is stored, looked up and matched by the word the backticks escape, while a raw identifier, which cannot be written without them, keeps them.
@Suite(.temporaryDirectories)
struct BacktickedNameTests {
    private static var source: String {
        """
        public struct Tick {
            public func `settle`(`in` slot: Int) {}
            public var `count`: Int = 0
        }
        public struct `Pump` {
            func run() {}
        }
        extension `Pump` {
            func drain() {}
        }
        """
    }

    /// `where settle`, `where Tick.settle` and the backticked spelling all reach the function, and the property and the type are reached by their bare names too.
    @Test
    func whereReachesABacktickedDeclarationByItsBareName() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "backticked names, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        for query in ["settle", "Tick.settle", "Tick.`settle`", "settle(in:)", "count", "Tick.count", "Pump", "Pump.drain"] {
            let output = try await engine.lookup(symbol: query, freshness: freshness)
            #expect(output.contains("\ndeclarations ("), "where \(query):\n\(output)")
            #expect(!output.contains("no exact match"), "where \(query):\n\(output)")
        }
    }

    /// A digest of the type lists the backticked members under their bare names, and keeps the source's spelling in the signatures it shows.
    @Test
    func digestListsABacktickedMemberAndKeepsItsWrittenSignature() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "backticked names, unbuilt")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let tick = try engine.digest(target: "Tick", options: DigestOptions())
        #expect(tick.contains("public func `settle`(`in` slot: Int)"), "\(tick)")
        #expect(tick.contains("public var `count`: Int"), "\(tick)")
        let member = try engine.digest(target: "Tick.settle", options: DigestOptions())
        #expect(member.contains("`settle`"), "\(member)")
        let pump = try engine.digest(target: "Pump", options: DigestOptions())
        #expect(pump.contains("func drain()"), "\(pump)")
    }

    /// The parser stores the bare word for an escaped name and keeps the backticks of a raw identifier.
    @Test
    func theStoredNameDropsBackticksOnlyAroundAnOrdinaryWord() throws {
        let parsed = try TestSources.parsed(Self.source + "\nstruct Fixture {\n    func `a b`() {}\n}\n", path: "Sources/Lib/Lib.swift")
        let names = Set(parsed.symbols.map(\.name))

        #expect(names.isSuperset(of: ["Tick", "settle(in:)", "count", "Pump", "drain()", "`a b`()"]), "\(names.sorted())")
        #expect(!names.contains { $0.contains("`settle`") || $0.contains("`Pump`") }, "\(names.sorted())")
    }

    /// `search name:` matches the same spelling `where` looks up, qualified by the bare type name.
    @Test
    func searchMatchesABacktickedDeclarationByItsBareName() throws {
        let matches = try StructuralMatcher.matches(in: Self.source, path: "Sources/Lib/Lib.swift", query: StructuralQuery("name:settle"))

        #expect(matches.map(\.qualifiedName) == ["Tick.settle(in:)"])
    }

    /// The query side unwraps an ordinary word and a keyword, leaves a raw identifier and an unclosed backtick alone.
    @Test(arguments: [
        ("Tick.`settle`", "Tick.settle"),
        ("`default`", "default"),
        ("`a b`()", "`a b`()"),
        ("Tick.`settle", "Tick.`settle"),
        ("Tick.settle", "Tick.settle"),
    ])
    func aQueryIsUnwrappedByTheSameRule(written: String, asked: String) {
        #expect(SymbolNaming.unbackticked(written) == asked)
    }

    /// A digest asked for a member written in backticks serves that member's source, as one asked for by the bare name does.
    @Test
    func digestReachesAMemberAskedForInBackticks() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "backticked names, unbuilt")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let member = try engine.digest(target: "Tick.`settle`", options: DigestOptions())

        #expect(member.contains("public func `settle`(`in` slot: Int)"), "\(member)")
    }
}
