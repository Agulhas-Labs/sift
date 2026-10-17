//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which of the typealiases a type's answer follows a nested alias writing their shared name reaches, with no index store.
///
/// Swift's lookup stops at the first scope out declaring the name, so a nested alias writing a name its own type declares reaches that declaration alone, though a farther one of the name names the type too.
@Suite(.temporaryDirectories)
struct WhereAliasReachTests {
    private static var shadowed: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        typealias Crate = Gizmo
        enum Space {
            typealias Crate = App.Gizmo
            typealias Bin = Crate
            static func f() { _ = Bin("t") }
        }

        """
    }

    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    private static func lookupAcrossModules(_ symbol: String, app: String, lib: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Multi",
                targets: [
                    .target(name: "App"),
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(app, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(lib, to: "Sources/Lib/Types.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A nested alias writing a name its own type declares as a kept alias is kept through that one, not folded through a farther proven one of the name.
    @Test
    func aNestedAliasReachingANearerKeptAliasIsKept() async throws {
        let output = try await Self.lookup("Gizmo", declaring: Self.shadowed, calling: "")

        #expect(!output.contains("folded in here"), "\(output)")
        #expect(output.contains(
            "2 written as Sources.Space.Crate (App.Gizmo), a typealias of its path behind a leading name that may be its module, and Sources.Space.Bin (Crate), an alias of a kept typealias, and Sources.Crate, a typealias naming it whose name a kept one shares, kept as uses though not proven to name it, as this type's module is guessed from the path; 1 more line declaring a typealias of it, which is another name for the type rather than use of it (for Sources.Gizmo)"
        ), "\(output)")
    }

    /// A call through a nested alias reaching a nearer kept alias is not counted as the initializer's, folded in.
    @Test
    func aCallThroughANestedAliasReachingANearerKeptAliasIsNotFolded() async throws {
        let output = try await Self.lookup("Gizmo.init", declaring: Self.shadowed, calling: "")

        #expect(!output.contains("folded in here"), "\(output)")
        #expect(output.contains(
            "\"Gizmo.init\" (1 call site by written name, 1 written as Sources.Space.Bin (Crate), an alias of a kept typealias, kept as a use though not proven to name it, as this type's module is guessed from the path, in 1 file):"
        ), "\(output)")
    }

    /// A nested alias in a type below an unseen supertype is folded in where the name it writes has a single declaration.
    @Test
    func aNestedAliasOfTheOnlyDeclarationIsFolded() async throws {
        let output = try await Self.lookup(
            "Gizmo",
            declaring: """
            import AppKit

            struct Gizmo {
                init(_ name: String) {}
            }
            class Panel: NSObject {
                typealias Bin = Gizmo
            }
            """,
            calling: """
            extension Panel {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains(
            "\"Gizmo\" (1 use by written name in 1 file) — 1 production · 0 tests; 1 written as Sources.Panel.Bin, a typealias naming it, folded in here; 1 more line declaring a typealias of it, which is another name for the type rather than use of it (for Sources.Gizmo):"
        ), "\(output)")
    }

    /// A nested alias writing a name two modules declare at their top levels is folded into its own module's type, since a module's own declaration hides an imported one.
    @Test
    func aNestedAliasOfATypeTwoModulesDeclareIsFoldedIntoItsOwnModules() async throws {
        let output = try await Self.lookupAcrossModules(
            "Lib.Gizmo",
            app: """
            struct Gizmo {
                init(_ name: String) {}
            }
            """,
            lib: """
            struct Gizmo {
                init(_ name: String) {}
            }
            enum Shelf {
                typealias Bin = Gizmo
            }
            extension Shelf {
                func one() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains(
            "\"Gizmo\" (1 use by written name in 1 file) — 1 production · 0 tests; 1 written as Lib.Shelf.Bin, a typealias naming it, folded in here; 1 more line declaring a typealias of it, which is another name for the type rather than use of it (for Lib.Gizmo):"
        ), "\(output)")
        #expect(output.contains(":8  | func one() { _ = Bin(\"t\") }"), "\(output)")
    }
}
