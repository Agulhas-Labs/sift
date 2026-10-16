//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's call sites written through a typealias whose name another declaration shares, with no index store.
///
/// A call through the alias's name is read by the scope it is written in: inside a type or function that declares its own of the name it is that declaration's, so it is dropped and counted.
@Suite(.temporaryDirectories)
struct WhereInitAliasShadowTests {
    private static var base: String {
        """
        struct Gizmo { init(_ name: String) {} }
        struct Other { init(_ name: String) {} }
        struct Plain { let v: Int }
        typealias Crate = Gizmo
        typealias PA = Plain
        enum Space { typealias Crate = Other; typealias PA = Other }
        """
    }

    private static var droppedInType: String {
        "1 written as \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, dropped"
    }

    private static var droppedInFunction: String {
        "1 written as \"Crate\" bare inside a function that declares its own \"Crate\", which is what the name means there, dropped"
    }

    private static var folded: String {
        "1 written as Sources.Crate, a typealias naming it, folded in here"
    }

    private static var kept: String {
        "1 written as Sources.Crate, a typealias naming it whose name another declaration shares, kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static func lookup(_ symbol: String, declaring declarations: String = base, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    private static func expectClauses(_ output: String, present: [String], absent: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for clause in present {
            #expect(output.contains(clause), "missing: \(clause)\n\(output)", sourceLocation: sourceLocation)
        }
        for clause in absent {
            #expect(!output.contains(clause), "unexpected: \(clause)\n\(output)", sourceLocation: sourceLocation)
        }
    }

    @Test
    func aCallInATypeDeclaringItsOwnIsDroppedAndOneOutsideIsFolded() async throws {
        let output = try await Self.lookup("Gizmo.init", calling: """
        extension Space {
            func make() { _ = Crate("t") }
        }
        struct Shop {
            func make() { _ = Crate("t") }
        }
        """)

        #expect(output.contains(":5  in Shop.make()"), "\(output)")
        #expect(!output.contains(":2  in"), "\(output)")
        Self.expectClauses(output, present: [Self.droppedInType, Self.folded], absent: [])
    }

    @Test
    func aCallBelowASupertypeOutsideTheIndexIsKeptAsUnproven() async throws {
        let output = try await Self.lookup("Gizmo.init", calling: """
        class Panel: NSObject {
            func make() { _ = Crate("t") }
        }
        """)

        #expect(output.contains(":2  in"), "\(output)")
        Self.expectClauses(output, present: [Self.kept], absent: [Self.folded, Self.droppedInType])
    }

    @Test
    func aQualifiedCallIsKept() async throws {
        let output = try await Self.lookup("Gizmo.init", calling: """
        struct Shop {
            func make() { _ = Space.Crate("t") }
        }
        """)

        #expect(output.contains(":2  in"), "\(output)")
        Self.expectClauses(output, present: [], absent: [Self.folded, Self.droppedInType])
    }

    @Test
    func aCallInAFunctionDeclaringItsOwnTypeIsDropped() async throws {
        let output = try await Self.lookup("Gizmo.init", calling: """
        struct Shop {
            func make() {
                struct Crate { init(_ s: String) {} }
                _ = Crate("t")
            }
        }
        """)

        #expect(!output.contains(":4  in"), "\(output)")
        Self.expectClauses(output, present: [Self.droppedInFunction], absent: [Self.folded])
    }

    @Test
    func aCallInAFunctionDeclaringItsOwnAliasIsKept() async throws {
        let output = try await Self.lookup("Gizmo.init", calling: """
        struct Shop {
            func make() {
                typealias Crate = Other
                _ = Crate("t")
            }
        }
        """)

        #expect(output.contains(":4  in"), "\(output)")
        Self.expectClauses(output, present: [], absent: [Self.folded, Self.droppedInFunction])
    }

    @Test
    func aMemberwiseCallInATypeDeclaringItsOwnIsDropped() async throws {
        let output = try await Self.lookup("Plain.init", calling: """
        extension Space {
            func make() { _ = PA(v: 1) }
        }
        """)
        let dropped = "1 written as \"PA\" bare inside a type that declares its own \"PA\", which is what the name means there, dropped"
        #expect(!output.contains(":2  in"), "\(output)")
        Self.expectClauses(output, present: [dropped], absent: [])
    }

    @Test
    func aCallWithNoOtherDeclarationIsFoldedIn() async throws {
        let output = try await Self.lookup("Gizmo.init", declaring: """
        struct Gizmo { init(_ name: String) {} }
        typealias Crate = Gizmo
        """, calling: """
        struct Shop {
            func make() { _ = Crate("t") }
        }
        """)

        #expect(output.contains(":2  in"), "\(output)")
        Self.expectClauses(output, present: [Self.folded], absent: [Self.droppedInType])
    }
}
