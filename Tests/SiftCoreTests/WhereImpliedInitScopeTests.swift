//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's implied call sites, written with a leading dot under a type annotation, whose annotation names a declaration local to the body around it.
///
/// The annotation's own scope decides what its name means: a declaration in the body shadows the alias there, while a return type sits outside the body and keeps the alias.
@Suite(.temporaryDirectories)
struct WhereImpliedInitScopeTests {
    private static var base: String {
        """
        struct Gizmo { init(_ name: String) {} }
        struct Other { init(_ name: String) {} }
        typealias Crate = Gizmo
        """
    }

    private static let implied = "." + "init"

    private static var droppedInFunction: String {
        "1 written as \"Crate\" bare inside a function that declares its own \"Crate\", which is what the name means there, dropped"
    }

    private static var kept: String {
        "kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static var folded: String {
        "a typealias naming it, folded in here"
    }

    private static func lookup(calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(base, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Gizmo.init", freshness: freshness)
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
    func anAnnotationNamingALocalTypeIsDroppedAndCounted() async throws {
        let output = try await Self.lookup(calling: """
        func c() { struct Crate { init(_ s: String) {} }; let k: Crate = \(Self.implied)("z") }
        """)

        Self.expectClauses(output, present: [Self.droppedInFunction], absent: [Self.folded])
    }

    @Test
    func anAnnotationNamingALocalTypealiasOfAnotherTypeIsKeptButNotProven() async throws {
        let output = try await Self.lookup(calling: """
        func d() { typealias Crate = Other; let m: Crate = \(Self.implied)("w") }
        """)

        Self.expectClauses(output, present: [Self.kept], absent: [Self.folded, Self.droppedInFunction])
    }

    @Test
    func aReturnTypeOutsideTheBodyKeepsTheAlias() async throws {
        let output = try await Self.lookup(calling: """
        func e() -> Crate { struct Crate { init(_ s: String) {} }; return \(Self.implied)("x") }
        """)

        Self.expectClauses(output, present: [Self.folded], absent: [Self.droppedInFunction])
    }

    @Test
    func anAnnotationWithNoLocalDeclarationStaysFolded() async throws {
        let output = try await Self.lookup(calling: """
        func f() { let k: Crate = \(Self.implied)("z") }
        """)

        Self.expectClauses(output, present: [Self.folded], absent: [Self.droppedInFunction])
    }
}
