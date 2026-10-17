//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's implied call sites, written with a leading dot, whose type annotation wraps the alias in a collection, an optional or an async result.
///
/// With no index store the annotation names the type, so each shape is still a use of the initializer through the alias.
@Suite(.temporaryDirectories)
struct WhereImpliedInitAnnotationShapeTests {
    private static var base: String {
        """
        struct Gizmo { init(_ name: String) async throws {} }
        typealias Crate = Gizmo
        """
    }

    private static let implied = "." + "init"

    private static var folded: String {
        "1 written as Sources.Crate, a typealias naming it, folded in here"
    }

    private static var untold: String {
        "on a type the scan cannot tell"
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

    @Test
    func aComputedPropertyAnnotationKeepsTheAliasAtTopLevel() async throws {
        let output = try await Self.lookup(calling: """
        var x: Crate { struct Crate { init(_ s: String) {} }; return \(Self.implied)("a") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(output.contains("in x "), "\(output)")
    }

    @Test
    func aComputedPropertyAnnotationKeepsTheAliasAsAMember() async throws {
        let output = try await Self.lookup(calling: """
        struct T { var x: Crate { struct Crate { init(_ s: String) {} }; return \(Self.implied)("a") } }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(output.contains("in T.x "), "\(output)")
    }

    @Test
    func anArrayAnnotationIsAUse() async throws {
        let output = try await Self.lookup(calling: """
        let all: [Crate] = [\(Self.implied)("a")]
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(output.contains("in all"), "\(output)")
    }

    @Test
    func anAsyncThrowingReturnTypeIsAUse() async throws {
        let output = try await Self.lookup(calling: """
        func g() async throws -> Crate { try await \(Self.implied)("t") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(output.contains("in g()"), "\(output)")
    }

    @Test
    func anOptionalAnnotationIsAUse() async throws {
        let output = try await Self.lookup(calling: """
        let maybe: Crate? = \(Self.implied)("o")
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(output.contains("in maybe"), "\(output)")
    }

    @Test
    func aClosureTypeAnnotationIsAUse() async throws {
        let output = try await Self.lookup(calling: """
        let make: () -> Crate = { \(Self.implied)("k") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(!output.contains(Self.untold), "\(output)")
    }

    @Test
    func aClosureSignatureReturnTypeIsAUse() async throws {
        let output = try await Self.lookup(calling: """
        let make = { () -> Crate in \(Self.implied)("k") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(!output.contains(Self.untold), "\(output)")
    }

    @Test
    func aClosurePassedAsAnArgumentStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        func run(_ body: () -> Crate) {}
        func g() { run { \(Self.implied)("k") } }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aMultiStatementClosureBodyStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        let make: () -> Crate = {
            let n = 1
            return \(Self.implied)("k")
        }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    private static var builder: String {
        """
        @resultBuilder enum Build {
            static func buildExpression(_ g: Gizmo) -> [Gizmo] { [g] }
            static func buildBlock(_ p: [Gizmo]...) -> [Gizmo] { p[0] }
            static func buildFinalResult(_ p: [Gizmo]) -> Gizmo { p[0] }
        }
        """
    }

    @Test
    func aClosureBoundToAResultBuilderParameterStaysUntold() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo { init(_ name: String) {} }\nstruct Crate { init(_ name: String) {}; init(parts: [Gizmo]) {} }", to: "Sources/App/Types.swift", in: root)
        try TestSources.write("""
        @resultBuilder enum Build {
            static func buildExpression(_ g: Gizmo) -> [Gizmo] { [g] }
            static func buildBlock(_ p: [Gizmo]...) -> [Gizmo] { p[0] }
            static func buildFinalResult(_ p: [Gizmo]) -> Crate { Crate(parts: p) }
        }
        func run(@Build _ body: () -> Crate) -> Crate { body() }
        let made = run { () -> Crate in \(Self.implied)("k") }
        """, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Gizmo.init", freshness: freshness)

        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aCustomAttributeOnTheDeclarationLeavesTheCallUntold() async throws {
        let output = try await Self.lookup(calling: """
        \(Self.builder)
        @Build var made: Crate { \(Self.implied)("k") }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aCompilerAttributeOnTheDeclarationStillFolds() async throws {
        let output = try await Self.lookup(calling: """
        @MainActor var made: Crate { \(Self.implied)("k") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(!output.contains(Self.untold), "\(output)")
    }

    @Test
    func aClosureBoundToAFunctionTypedLetStillFolds() async throws {
        let output = try await Self.lookup(calling: """
        let make: () -> Crate = { \(Self.implied)("k") }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(!output.contains(Self.untold), "\(output)")
    }

    @Test
    func aTrailingClosureOnASubscriptStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        \(Self.builder)
        struct Holder { subscript(@Build b: () -> Crate) -> Int { 0 } }
        let st = Holder()[] { () -> Crate in \(Self.implied)("x") }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aClosureInASubscriptArgumentListStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        \(Self.builder)
        struct Holder { subscript(@Build b b: () -> Crate) -> Int { 0 } }
        let st = Holder()[b: { () -> Crate in \(Self.implied)("x") }]
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aCustomAttributeOnAnAccessorLeavesTheCallUntold() async throws {
        let output = try await Self.lookup(calling: """
        \(Self.builder)
        var acc: Crate { @Build get { \(Self.implied)("x") } }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aLabelledCallArgumentClosureStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        func take(body: () -> Crate) {}
        func g() { take(body: { () -> Crate in \(Self.implied)("x") }) }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aMultipleTrailingClosureElementStaysUntold() async throws {
        let output = try await Self.lookup(calling: """
        func run(_ first: () -> Void, other: () -> Crate) {}
        func g() { run { } other: { () -> Crate in \(Self.implied)("x") } }
        """)

        #expect(!output.contains(Self.folded), "\(output)")
        #expect(output.contains(Self.untold), "\(output)")
    }

    @Test
    func aPlainAccessorStillFolds() async throws {
        let output = try await Self.lookup(calling: """
        var acc: Crate { get { \(Self.implied)("x") } }
        """)

        #expect(output.contains(Self.folded), "\(output)")
        #expect(!output.contains(Self.untold), "\(output)")
    }
}
