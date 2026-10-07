//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a conformance written inside a composition (`A & B`) listed among the protocol's conformers, once, with and without an index store.
@Suite(.temporaryDirectories, .serialized)
struct WhereCompositionConformerTests {
    /// Every composition shape Swift accepts in an inheritance clause, plus two that must not count: a composition inside a superclass's generic argument, and a protocol whose name holds the asked one's.
    private static var source: String {
        """
        enum Log {
            enum Shelf {
                protocol Answer {}
            }
        }
        protocol Reading {}
        protocol Ledger {}
        protocol Readings {}
        protocol Signal<Value> {
            associatedtype Value
        }
        class Base<Value> {}
        struct Pair: Log.Shelf.Answer & Sendable {}
        struct Flip: Sendable & Log.Shelf.Answer {}
        struct Three: Reading & Log.Shelf.Answer & Ledger {}
        struct Plain {}
        extension Plain: Reading & Ledger {}
        final class Sub: Base<Int> & Reading {}
        protocol Derived: Signal<Int> & Ledger {}
        struct Wrapped: (Reading & Ledger) {}
        struct Spread: Reading
            & Ledger {}
        final class Holder: Base<any Reading & Ledger> {}
        struct Stack: Readings & Sendable {}
        """
    }

    /// The rows under `conformers of <name> (`, each without its leading indent.
    private static func conformerRows(of name: String, in output: String) -> [String] {
        WhereConformersOnceTests.rowsUnder("conformers of \(name) (", in: output)
    }

    /// With no store, the written-name block lists each composition conformer of `Log.Shelf.Answer` once, whichever side of the `&` it stands on.
    @Test
    func aQualifiedProtocolInEitherOrderIsListedOnce() async throws {
        let output = try await WhereQualifiedProtocolNoteTests.answer("Log.Shelf.Answer", source: Self.source)

        #expect(output.contains("\nconformers of Answer (3, by written name):\n"), "\(output)")
        #expect(Self.conformerRows(of: "Answer", in: output) == [
            "Sources.Pair — struct — Sources/Lib/Lib.swift:13",
            "Sources.Flip — struct — Sources/Lib/Lib.swift:14",
            "Sources.Three — struct — Sources/Lib/Lib.swift:15",
        ], "\(output)")
    }

    /// Each declared component of a composition lists the conformer once, in an extension, after a generic superclass, in parentheses, across lines; a composition inside a generic argument and a longer protocol name do not count.
    @Test
    func eachComponentListsTheConformerOnce() async throws {
        let reading = try await WhereQualifiedProtocolNoteTests.answer("Reading", source: Self.source)
        let ledger = try await WhereQualifiedProtocolNoteTests.answer("Ledger", source: Self.source)

        #expect(Self.conformerRows(of: "Reading", in: reading) == [
            "Sources.Three — struct — Sources/Lib/Lib.swift:15",
            "Sources.Plain — extension — Sources/Lib/Lib.swift:17",
            "Sources.Sub — class — Sources/Lib/Lib.swift:18",
            "Sources.Wrapped — struct — Sources/Lib/Lib.swift:20",
            "Sources.Spread — struct — Sources/Lib/Lib.swift:21-22",
        ], "\(reading)")
        #expect(Self.conformerRows(of: "Ledger", in: ledger) == [
            "Sources.Three — struct — Sources/Lib/Lib.swift:15",
            "Sources.Plain — extension — Sources/Lib/Lib.swift:17",
            "Sources.Derived — protocol — Sources/Lib/Lib.swift:19",
            "Sources.Wrapped — struct — Sources/Lib/Lib.swift:20",
            "Sources.Spread — struct — Sources/Lib/Lib.swift:21-22",
        ], "\(ledger)")
    }

    /// A component with generic arguments names its protocol, and a protocol whose name holds another's is matched whole.
    @Test
    func genericAndLongerNamedComponentsMatchTheirOwnProtocol() async throws {
        let signal = try await WhereQualifiedProtocolNoteTests.answer("Signal", source: Self.source)
        let readings = try await WhereQualifiedProtocolNoteTests.answer("Readings", source: Self.source)

        #expect(Self.conformerRows(of: "Signal", in: signal) == ["Sources.Derived — protocol — Sources/Lib/Lib.swift:19"], "\(signal)")
        #expect(Self.conformerRows(of: "Readings", in: readings) == ["Sources.Stack — struct — Sources/Lib/Lib.swift:24"], "\(readings)")
    }

    /// `--refs` lists the same conformers block as the plain answer.
    @Test
    func theReferenceSweepListsTheSameConformers() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "compositions, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let plain = try await engine.lookup(symbol: "Reading", freshness: freshness)
        let swept = try await engine.lookup(symbol: "Reading", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(Self.conformerRows(of: "Reading", in: plain).count == 5, "\(plain)")
        #expect(Self.conformerRows(of: "Reading", in: swept) == Self.conformerRows(of: "Reading", in: plain), "\(swept)")
    }

    /// The component reader splits only outside generic arguments, drops parentheses and generic arguments, and keeps each qualifier.
    @Test
    func componentsAreReadOutsideGenericArguments() {
        #expect(InheritedClause.components(of: "Base<any Reading & Ledger>") == ["Base"])
        #expect(InheritedClause.components(of: "(Reading & Ledger)") == ["Reading", "Ledger"])
        #expect(InheritedClause.components(of: "Outer<Int>.Inner & Log.Shelf.Answer<Int>") == ["Outer.Inner", "Log.Shelf.Answer"])
        #expect(InheritedClause.components(of: "Reading\n    & Ledger") == ["Reading", "Ledger"])
        #expect(InheritedClause.components(of: ["Sendable & Log.Shelf.Answer"], naming: "Answer") == ["Log.Shelf.Answer"])
        #expect(!InheritedClause.names("Reading", in: ["Readings & Sendable"]))
    }
}
