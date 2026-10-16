//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's name-matched call sites written through a generic typealias of its type, or through a typealias of a type that declares no init of its own, with no index store.
///
/// The init answer follows the aliases the type's own answer follows: `Box<Int>("t")` with `typealias Box<T> = Gizmo` builds a `Gizmo`, and `PA(v: 1)` with `typealias PA = Plain` calls the memberwise init the compiler writes for `Plain`.
@Suite(.temporaryDirectories)
struct WhereInitThroughAliasRoundTwoTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A call through a generic typealias of the type, its generic arguments written, is listed and counted as the type's answer counts it.
    @Test
    func aCallThroughAGenericTypealiasIsListed() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            struct Gizmo {
                init(_ name: String) {}
            }
            typealias Box<T> = Gizmo
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo("t") }
                func two() { _ = Box<Int>("t") }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (2 call sites by written name, 1 written as Sources.Box, a typealias naming it, folded in here, in 1 file):"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
    }

    /// A call through a typealias of a struct that declares no init reaches the memberwise init the compiler writes, so it is listed with the direct one.
    @Test
    func aCallThroughATypealiasOfAMemberwiseStructIsListed() async throws {
        let output = try await Self.lookup(
            "Plain.init",
            declaring: """
            struct Plain {
                let v: Int
            }
            typealias PA = Plain
            """,
            calling: """
            struct Calls {
                func one() { _ = PA(v: 1) }
                func two() { _ = Plain(v: 2) }
            }
            """
        )

        #expect(output.contains("\"Plain.init\" (2 call sites by written name, 1 written as Sources.PA, a typealias naming it, folded in here, in 1 file):"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
    }

    /// A call through an alias of a struct that declares no init is kept whatever its labels, as a direct call is: the type may take an initializer the index cannot see.
    @Test
    func aCallThroughATypealiasOfAMemberwiseStructIsKeptWhateverItsLabels() async throws {
        let output = try await Self.lookup(
            "Plain.init",
            declaring: """
            struct Plain {
                let v: Int
            }
            typealias PA = Plain
            """,
            calling: """
            struct Calls {
                func one() { _ = PA(v: 1) }
                func two() { _ = PA(w: 1) }
            }
            """
        )

        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
        #expect(!output.contains("labels no init of it takes"), "\(output)")
    }

    /// An `OptionSet` takes its sequence initializer from `SetAlgebra`, which no indexed file declares, so a call through its alias reaches an initializer the labels alone cannot show.
    @Test
    func aCallThroughATypealiasReachingAnInitializerFromOutsideTheIndexIsKept() async throws {
        let output = try await Self.lookup(
            "Box.init",
            declaring: """
            struct Box: OptionSet {
                let rawValue: Int
                static let a = Box(rawValue: 1)
            }
            typealias Crate = Box
            """,
            calling: """
            struct Calls {
                func one() { _ = Crate([.a]) }
            }
            """
        )

        #expect(output.contains("in Calls.one()"), "\(output)")
    }

    /// An alias of an alias of a struct that declares no init is followed, as the type's own answer follows it.
    @Test
    func anAliasOfAnAliasOfAMemberwiseStructIsFollowed() async throws {
        let output = try await Self.lookup(
            "Plain.init",
            declaring: """
            struct Plain {
                let v: Int
            }
            typealias PA = Plain
            typealias PB = PA
            """,
            calling: """
            struct Calls {
                func one() { _ = PB(v: 1) }
                func two() { _ = PB.init(v: 2) }
            }
            """
        )

        #expect(output.contains("\"Plain.init\" (2 call sites by written name, 2 written as Sources.PB, a typealias naming it, folded in here, in 1 file):"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(output.contains("in Calls.two()"), "\(output)")
    }

    /// An alias handing a generic type its arguments still names it, while one whose outermost type is another, such as `Array`, builds that type and is not followed.
    @Test
    func anAliasSpecializingTheTypeIsFollowedAndOneWrappingItIsNot() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            struct Gizmo<T> {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo<Int>
            typealias Many = Array<Gizmo<Int>>
            """,
            calling: """
            struct Calls {
                func one() { _ = Crate("t") }
                func two() { _ = Many() }
            }
            """
        )

        #expect(output.contains("\"Gizmo.init\" (1 call site by written name, 1 written as Sources.Crate, a typealias naming it, folded in here, in 1 file):"), "\(output)")
        #expect(output.contains("in Calls.one()"), "\(output)")
        #expect(!output.contains("in Calls.two()"), "\(output)")
    }
}
