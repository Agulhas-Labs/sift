//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which typealiases declared in a type the chain a type's answer follows treats as another name for it, with no index store.
///
/// A nested alias writing a bare name means what that name, looked up from the alias's own scope, means: `typealias Bin = Crate` inside a type that declares its own `Crate` names that one, not a top-level `Crate` aliasing the type asked.
@Suite(.temporaryDirectories)
struct WhereAliasChainScopeTests {
    private static var base: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        struct Other {
            init(_ name: String) {}
        }
        typealias Crate = Gizmo

        """
    }

    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(base + declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A nested alias writing a name its own type declares names that declaration, so it is no alias of the type and its uses are not the type's.
    @Test
    func aNestedAliasWritingItsTypesOwnNameIsNotFollowed() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            enum Space {
                typealias Crate = Other
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Space {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(!output.contains("Sources.Space.Bin"), "\(output)")
        #expect(output.contains(
            "1 more line declaring a typealias of it, which is another name for the type rather than use of it; 1 more line writing \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, so not use (for Sources.Gizmo)"
        ), "\(output)")
    }

    /// A nested alias in a type declaring no other of the name it writes is folded in, though another type declares one.
    @Test
    func aNestedAliasReachingTheTopLevelAliasIsFolded() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            enum Space {
                typealias Crate = Other
            }
            enum Shop {
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Shop {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains("1 written as Sources.Shop.Bin, a typealias naming it, folded in here"), "\(output)")
    }

    /// A nested alias below a supertype outside the index, which may declare its own of the name, is kept, worded unproven.
    @Test
    func aNestedAliasBelowAnUnseenSupertypeIsKept() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            import Foundation
            enum Space {
                typealias Crate = Other
            }
            class Panel: NSObject {
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Panel {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains(
            "2 written as Sources.Crate, a typealias naming it whose name another declaration shares, and Sources.Panel.Bin (Crate), a typealias writing a name another declaration shares, kept as uses though not proven to name it, as the name may mean that other declaration where it is written"
        ), "\(output)")
        #expect(!output.contains("written as Sources.Panel.Bin"), "\(output)")
    }

    /// The initializer's calls follow the same chain, so a call through a nested alias naming another declaration is not the type's.
    @Test
    func aCallThroughAShadowedNestedAliasIsNotTheInitializers() async throws {
        let output = try await Self.lookup(
            "Gizmo.init",
            declaring: """
            enum Space {
                typealias Crate = Other
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Space {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains("no call spelled \"Gizmo.init\" anywhere in the working tree"), "\(output)")
        #expect(!output.contains("Bin(\"t\")"), "\(output)")
        #expect(!output.contains("Sources.Space.Bin"), "\(output)")
    }

    /// A nested alias of a name nothing else declares is folded in, as before.
    @Test
    func aNestedAliasOfAnUnsharedNameIsFolded() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            enum Shop {
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Shop {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains("1 written as Sources.Shop.Bin, a typealias naming it, folded in here"), "\(output)")
    }
}
