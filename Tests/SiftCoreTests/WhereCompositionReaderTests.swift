//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the composition reader on a function type inside a generic argument and on comments inside a composition: neither makes a false conformer, and a comment between components no longer hides one.
@Suite(.temporaryDirectories)
struct WhereCompositionReaderTests {
    private static var source: String {
        """
        protocol Reading {}
        protocol Ledger {}
        protocol Readings {}
        class Base<Value> {}
        final class F5: Base<(Int) -> any Reading & Ledger> {}
        final class F6: Base<(Int) -> Readings> & Sendable {}
        struct F8: Ledger // see Reading
            & Sendable {}
        struct C4: Ledger /* note */ & Reading {}
        struct C5: Ledger // note
            & Reading {}
        """
    }

    /// The `->` of a function type inside a generic argument closes nothing, so what follows it stays inside the argument.
    @Test
    func aFunctionTypeInsideAGenericArgumentIsNotAComponent() {
        #expect(InheritedClause.components(of: "Base<(Int) -> any Reading & Ledger>") == ["Base"])
        #expect(InheritedClause.components(of: "Base<(Int) -> Readings> & Sendable") == ["Base", "Sendable"])
    }

    /// A comment is not part of a component: the word before it stays the last word, a block comment between components keeps them apart.
    @Test
    func commentsInsideACompositionAreDropped() {
        #expect(InheritedClause.components(of: "Ledger // see Reading\n    & Sendable") == ["Ledger", "Sendable"])
        #expect(InheritedClause.components(of: "Ledger /* note */ & Reading") == ["Ledger", "Reading"])
        #expect(InheritedClause.components(of: "Ledger // note\n    & Reading") == ["Ledger", "Reading"])
        #expect(InheritedClause.components(of: "Ledger/* a */Reading") == ["Reading"])
        #expect(InheritedClause.components(of: "Ledger & /* open") == ["Ledger"])
    }

    /// With no store, each protocol's written-name block lists exactly the true conformers.
    @Test(arguments: [
        ("Reading", ["Sources.C4 — struct — Sources/Lib/Lib.swift:9", "Sources.C5 — struct — Sources/Lib/Lib.swift:10-11"]),
        ("Ledger", ["Sources.F8 — struct — Sources/Lib/Lib.swift:7-8", "Sources.C4 — struct — Sources/Lib/Lib.swift:9", "Sources.C5 — struct — Sources/Lib/Lib.swift:10-11"]),
        ("Readings", []),
    ])
    func theWrittenNameBlockListsOnlyTrueConformers(name: String, rows: [String]) async throws {
        let output = try await WhereQualifiedProtocolNoteTests.answer(name, source: Self.source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of \(name) (", in: output) == rows, "\(output)")
    }

    /// The store's conformers, the dynamic-member walk and the several-owners walk (all `conformers(of:)`), and the supertypes walk, read the same components.
    @Test
    func theStoreWalksReadTheSameComponents() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "composition reader fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        func conformers(_ name: String) throws -> [String] {
            try engine.store.conformers(of: name).map(\.name).sorted()
        }
        #expect(try conformers("Reading") == ["C4", "C5"])
        #expect(try conformers("Ledger") == ["C4", "C5", "F8"])
        #expect(try conformers("Readings").isEmpty)

        let receivers = MemberReceivers(store: engine.store)
        for (type, expected) in [("F5", ["Base"]), ("F6", ["Base", "Sendable"]), ("F8", ["Ledger", "Sendable"]), ("C4", ["Ledger", "Reading"])] {
            let names = try receivers.supertypes(of: [type], aliases: [:]).names
            #expect(names == Set(expected), "\(type): \(names)")
        }
    }
}
