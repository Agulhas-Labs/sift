//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's name-matched call sites written through a typealias of its type, with no index store.
///
/// A call written `Crate("t")` or `Crate.init("t")`, where `typealias Crate = Gizmo`, builds a `Gizmo` as surely as `Gizmo("t")` does, so a rename or delete sweep of `Gizmo.init` needs it listed; the type's own answer already folds such uses in and says how many.
@Suite(.temporaryDirectories)
struct WhereInitThroughAliasTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A call through a typealias, bare or by `.init`, is listed with the direct one and counted on the count line.
    @Test
    func aCallThroughATypealiasIsListed() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo("t") }
                func two() { _ = Crate("t") }
                func three() { _ = Crate.init("t") }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (3 call sites by written name, 2 written as Sources.Crate, a typealias naming it, folded in here, in 1 file"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
        #expect(output.contains("in Calls.three()"), "\(output)")
    }

    /// An alias of an alias is followed, as the type's own answer follows it.
    @Test
    func anAliasOfAnAliasIsFollowed() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo
            typealias Box = Crate
            """,
            calling: """
            struct Calls {
                func one() { _ = Box("t") }
                func two() { _ = Box.init("t") }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (2 call sites by written name, 2 written as Sources.Box, a typealias naming it, folded in here, in 1 file):"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
    }

    /// A call through an alias whose labels reach no asked initializer is dropped by label narrowing, as a direct one is.
    @Test
    func aCallThroughAnAliasIsNarrowedByItsLabels() async throws {
        let output = try await Self.lookup(
            "Gizmo.init(_:)",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo(size: 1) }
                func two() { _ = Crate("t") }
                func three() { _ = Crate(size: 1) }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (3 call sites by written name, 2 written as Sources.Crate, a typealias naming it, folded in here, 1 with the labels (_:), in 1 file; labels narrowed):"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
        #expect(!output.contains("in Calls.one()"), "\(output)")
        #expect(!output.contains("in Calls.three()"), "\(output)")
    }

    /// The type's own answer still folds in its uses through the alias, and says how many.
    @Test
    func theTypesOwnAnswerIsUnchanged() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo("t") }
                func two() { _ = Crate("t") }
            }
            """
        )

        #expect(output.contains("\"Gizmo\" (2 uses by written name in 1 file) — 2 production · 0 tests; 1 written as Sources.Crate, a typealias naming it, folded in here; 1 more line declaring a typealias of it"), "\(output)")
    }

    /// An alias of the same name naming another type is no alias of this one, so a call through it is not this type's.
    @Test
    func aSameNamedAliasOfAnotherTypeIsNotFolded() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            struct Widget {
                init(_ name: String) {}
            }
            typealias Crate = Widget
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo("t") }
                func two() { _ = Crate("t") }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (1 call site by written name in 1 file"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(!output.contains("in Calls.two()"), "\(output)")
        #expect(!output.contains("written as"), "\(output)")
    }
}
