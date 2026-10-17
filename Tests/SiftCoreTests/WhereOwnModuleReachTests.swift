//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a nested typealias writing a name two modules declare at their top levels, with no index store.
///
/// Swift reads an unqualified name in a module's file as that module's own top-level declaration over any imported module's, so a nested alias writing a name its own module certainly declares names that declaration.
@Suite(.temporaryDirectories)
struct WhereOwnModuleReachTests {
    private static var app: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        """
    }

    private static var lib: String {
        """
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
    }

    private static var conditionalLib: String {
        """
        #if DEBUG
        struct Gizmo {
            init(_ name: String) {}
        }
        #endif
        enum Shelf {
            typealias Bin = Gizmo
        }
        extension Shelf {
            func one() { _ = Bin("t") }
        }
        """
    }

    private static var rack: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        enum Rack {
            typealias Bin = Gizmo
        }
        extension Rack {
            func one() { _ = Bin("t") }
        }
        """
    }

    private static var shelfOnly: String {
        """
        enum Shelf {
            typealias Bin = Gizmo
        }
        extension Shelf {
            func one() { _ = Bin("t") }
        }
        """
    }

    private static func lookupAcrossModules(_ symbol: String, app: String, lib: String, libExtra: String? = nil, libDirectory: String = "Sources/Lib") async throws -> String {
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
        try TestSources.write(lib, to: libDirectory + "/Types.swift", in: root)
        if let libExtra {
            try TestSources.write(libExtra, to: libDirectory + "/More.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    private static func expectKept(_ output: String, as alias: String = "Lib.Shelf.Bin", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!output.contains("folded in here"), "\(output)", sourceLocation: sourceLocation)
        #expect(output.contains(
            "\"Gizmo\" (2 uses by written name in 1 file) — 2 production · 0 tests; 1 written as \(alias) (Gizmo), a typealias writing a name another declaration shares, kept as a use though not proven to name it, as the name may mean that other declaration where it is written (for Lib.Gizmo):"
        ), "\(output)", sourceLocation: sourceLocation)
    }

    /// A call through a nested alias writing a name its own module declares at the top level is counted as that type's initializer's, folded in, though another module declares the name too.
    @Test
    func aCallThroughANestedAliasOfItsOwnModulesTypeIsFolded() async throws {
        let output = try await Self.lookupAcrossModules("Lib.Gizmo.init", app: Self.app, lib: Self.lib)

        #expect(output.contains(
            "\"Gizmo.init\" (1 call site by written name, 1 written as Lib.Shelf.Bin, a typealias naming it, folded in here, in 1 file):"
        ), "\(output)")
    }

    /// A nested alias in the other module writing the shared name is folded into that module's own type.
    @Test
    func aNestedAliasInTheOtherModuleIsFoldedIntoThatModulesType() async throws {
        let output = try await Self.lookupAcrossModules("App.Gizmo", app: Self.rack, lib: Self.app)

        #expect(output.contains(
            "\"Gizmo\" (1 use by written name in 1 file) — 1 production · 0 tests; 1 written as App.Rack.Bin, a typealias naming it, folded in here; 1 more line declaring a typealias of it, which is another name for the type rather than use of it (for App.Gizmo):"
        ), "\(output)")
    }

    /// A nested alias in the other module writing the shared name stays kept for the type it does not name: the own-module rule proves a reach and never drops one.
    @Test
    func aNestedAliasInTheOtherModuleStaysKeptForTheTypeItDoesNotName() async throws {
        let output = try await Self.lookupAcrossModules("Lib.Gizmo", app: Self.rack, lib: Self.app)

        Self.expectKept(output, as: "App.Rack.Bin")
    }

    /// An own-module declaration of the name under `#if` is not certain, so the alias stays kept.
    @Test
    func anOwnModuleDeclarationUnderIfConfigLeavesTheAliasKept() async throws {
        let output = try await Self.lookupAcrossModules("Lib.Gizmo", app: Self.app, lib: Self.conditionalLib)

        #expect(output.contains("[#if DEBUG]"), "\(output)")
        Self.expectKept(output)
    }

    /// An own-module declaration of the name in a module guessed from the path is not certain, so the alias stays kept.
    @Test
    func anOwnModuleDeclarationInAGuessedModuleLeavesTheAliasKept() async throws {
        let output = try await Self.lookupAcrossModules("Lib.Gizmo", app: Self.app, lib: Self.lib, libDirectory: "Lib")

        #expect(output.contains("Lib.Gizmo — struct — struct Gizmo — Lib/Types.swift:1-3"), "\(output)")
        Self.expectKept(output)
    }

    /// A `private` own-module declaration of the name in another file is not visible to the alias, so the alias stays kept.
    @Test
    func aPrivateOwnModuleDeclarationInAnotherFileLeavesTheAliasKept() async throws {
        let output = try await Self.lookupAcrossModules("Lib.Gizmo", app: Self.app, lib: Self.shelfOnly, libExtra: "private struct Gizmo {\n    init(_ name: String) {}\n}\n")

        #expect(output.contains("private struct Gizmo — Sources/Lib/More.swift:1-3"), "\(output)")
        Self.expectKept(output)
    }

    /// Asked together, both modules' types still fold the call through the nested alias in.
    @Test
    func bothModulesTypesAskedTogetherStillFoldTheAlias() async throws {
        let output = try await Self.lookupAcrossModules("Gizmo.init", app: Self.app, lib: Self.lib)

        #expect(output.contains(
            "\"Gizmo.init\" (1 call site by written name, 1 written as Lib.Shelf.Bin, a typealias naming it, folded in here, in 1 file — for both):"
        ), "\(output)")
    }
}
