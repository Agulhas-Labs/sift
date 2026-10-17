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

    private static var droppedAnywhere: String {
        "written as \"Crate\" bare inside a function that declares its own \"Crate\""
    }

    private static var kept: String {
        "kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static var folded: String {
        "a typealias naming it, folded in here"
    }

    private static func lookup(calling calls: String) async throws -> String {
        try await lookup(declaring: base, calling: calls)
    }

    /// The answer to `where Gizmo.init` over `types` and `calls`, each its own file.
    private static func lookup(declaring types: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(types, to: "Sources/App/Types.swift", in: root)
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

    @Test
    func aClosureTypeAnnotationNamingALocalTypeIsDropped() async throws {
        let output = try await Self.lookup(calling: """
        func f() { struct Crate { init(_ s: String) {} }; let make: () -> Crate = { \(Self.implied)("k") } }
        """)

        Self.expectClauses(output, present: [Self.droppedInFunction], absent: [Self.folded])
    }

    @Test
    func anAnnotationInAPlainTypeInsideTheBodyIsDroppedAndCounted() async throws {
        let output = try await Self.lookup(calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            struct Box {
                subscript(i: Int) -> Crate { \(Self.implied)("s") }
                var c: Crate { \(Self.implied)("c") }
            }
        }
        """)

        Self.expectClauses(output, present: [Self.droppedInFunction.replacingOccurrences(of: "1 written", with: "2 written")], absent: [Self.kept, Self.folded])
    }

    @Test(arguments: [
        "struct Box: Base {",
        "struct Box<T> {",
        "@Observable final class Box {",
        "struct Box { typealias Crate = Other",
        "struct Box { struct Crate { init(_ s: String) {} }",
        "struct Box {\n#if DEBUG\ntypealias Crate = Other\n#endif",
        "struct Box { #makeGizmo",
        "struct Box {}; extension Box {",
    ])
    func anAnnotationInATypeTheNameMayResolveInIsKept(opening box: String) async throws {
        let output = try await Self.lookup(calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            \(box)
                var c: Crate { \(Self.implied)("c") }
            }
        }
        """)

        Self.expectClauses(output, present: [Self.kept], absent: [Self.folded, Self.droppedAnywhere])
    }

    @Test
    func anAnnotationNamingAGenericParameterOfAPlainTypesMemberIsKept() async throws {
        let output = try await Self.lookup(calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            struct Box {
                subscript<Crate>(i: Crate) -> Crate { \(Self.implied)("s") }
            }
        }
        """)

        Self.expectClauses(output, present: [Self.kept], absent: [Self.folded, Self.droppedAnywhere])
    }

    @Test
    func anAnnotationNamingAGenericParameterOfANestedFunctionIsKept() async throws {
        let output = try await Self.lookup(calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            func g<Crate>(_ c: Crate) { let k: Crate = \(Self.implied)("z") }
        }
        """)

        Self.expectClauses(output, present: [Self.kept], absent: [Self.folded, Self.droppedAnywhere])
    }

    @Test
    func aCallInAnActorOrAPayloadFreeEnumInsideTheBodyIsKept() async throws {
        let output = try await Self.lookup(declaring: """
        struct Gizmo { init(_ name: String) {} }
        extension Actor { typealias Crate = Gizmo }
        extension Hashable { typealias Bin = Gizmo }
        """, calling: """
        func f() { struct Crate { init(_ s: String) {} }
            actor Box { nonisolated func make() { _ = Crate("d") } } }
        func g() { struct Bin { init(_ s: String) {} }
            enum Box2 { case a; func make() { _ = Bin("f") } } }
        """)

        Self.expectClauses(output, present: [":2  in f().Box.make()", ":4  in g().Box2.make()", "kept as uses though not proven to name it"], absent: ["no call spelled", "inside a function that declares its own"])
    }

    @Test(arguments: [
        (conformance: "Actor", opening: "actor Box { nonisolated"),
        (conformance: "Equatable", opening: "enum Box { case a;"),
        (conformance: "Hashable", opening: "enum Box { case a;"),
    ])
    func aCallInATypeConformingWithoutSayingSoIsKept(conformance: String, opening box: String) async throws {
        let output = try await Self.lookup(declaring: """
        struct Gizmo { init(_ name: String) {} }
        extension \(conformance) { typealias Crate = Gizmo }
        """, calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            \(box) func make() { _ = Crate("d") } }
        }
        """)

        Self.expectClauses(output, present: [":3  in f().Box.make()", Self.kept], absent: ["no call spelled", "inside a function that declares its own"])
    }

    @Test(arguments: [
        (conformance: "Actor", opening: "actor Box { nonisolated"),
        (conformance: "Hashable", opening: "enum Box { case a;"),
    ])
    func anAnnotationInATypeConformingWithoutSayingSoIsDropped(conformance: String, opening box: String) async throws {
        let output = try await Self.lookup(declaring: """
        struct Gizmo { init(_ name: String) {} }
        extension \(conformance) { typealias Crate = Gizmo }
        """, calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            \(box) var c: Crate { \(Self.implied)("c") } }
        }
        """)

        Self.expectClauses(output, present: [Self.droppedAnywhere], absent: [Self.kept])
    }

    @Test
    func aCallInAPlainStructInsideTheBodyIsDropped() async throws {
        let output = try await Self.lookup(declaring: """
        struct Gizmo { init(_ name: String) {} }
        extension Hashable { typealias Crate = Gizmo }
        """, calling: """
        func f() {
            struct Crate { init(_ s: String) {} }
            struct Box { func make() { _ = Crate("d") } }
        }
        """)

        Self.expectClauses(output, present: [Self.droppedAnywhere], absent: [Self.kept])
    }
}
