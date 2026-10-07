//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a type's name-matched stand-in for the store's usage verdict: with no store to answer, `where` lists every place the type's name is written, never only the calls spelling it.
///
/// A type used only through its static members and in annotations is called nowhere by its own name, so a scan for calls answered "no call spelled" of it, which a reader takes for "unused" and deletes.
@Suite(.temporaryDirectories)
struct WhereTypeSyntacticUsageTests {
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Gizmo {
                public static func make() -> Gizmo { Gizmo() }
            }
            extension Gizmo {
                static let shared = Gizmo.make()
            }
            public struct Crate {}
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Holder {
                let gizmo: Gizmo
                func build() -> [Gizmo] { [Gizmo.make()] }
                func check(_ value: Any) -> Bool { value is Gizmo }
            }
            """,
            to: "Sources/App/Holder.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing

            struct Checks {
                @Test func build() { _ = Gizmo.self }
            }
            """,
            to: "Tests/AppTests/Checks.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "type usage fixture, unbuilt")
        return root
    }

    /// Static members, an annotation, a generic argument, a cast and `T.self` are all uses, grouped per file and split on the file's imports, with the type's own lines counted apart.
    @Test
    func aTypeUsedOnlyThroughStaticMembersAndAnnotationsIsListedAsUsed() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Gizmo", freshness: freshness)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(!output.contains("no use spelled"), "\(output)")
        #expect(output.contains("\"Gizmo\" used by 4 lines in 2 files — 3 production · 1 test, split on the XCTest or Testing import, never the path; 3 more lines inside its own declaration or its extensions in this module, which is not use (for "), "\(output)")
        #expect(output.contains("\n  Sources/App/Holder.swift (3):\n    :2  | let gizmo: Gizmo\n    :3  | func build() -> [Gizmo] { [Gizmo.make()] }\n    :4  | func check(_ value: Any) -> Bool { value is Gizmo }\n"), "\(output)")
        #expect(output.contains("\n  Tests/AppTests/Checks.swift (1):\n    :4  | @Test func build() { _ = Gizmo.self }"), "\(output)")
        // Leads, not resolved locations: every row stays inside the name-matched block a reader of the answer skips.
        let outside = NameMatchedSites.linesOutside(answer: output).joined(separator: "\n")
        #expect(!outside.contains("Holder.swift"), "\(outside)")
        #expect(!outside.contains("Checks.swift"), "\(outside)")
    }

    /// A type nothing writes is answered with a sentence saying its uses were searched, not only its calls.
    @Test
    func aTypeWithNoUseSaysUsesWereSearched() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Crate", freshness: freshness)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(output.contains("no use spelled \"Crate\" anywhere — no construction, no member reached through it, and no annotation, generic argument, conformance, cast or attribute naming it; a string literal is not searched (for "), "\(output)")
        #expect(!output.contains("\"Crate\" used by"), "\(output)")
    }

    /// A type of the same name nested in another module, and another module's extension of the type, are not the type declaring itself: the lines inside them that name it are uses, as the store counts them.
    @Test
    func linesInsideASameNamedTypeOrAnotherModulesExtensionAreUses() async throws {
        let output = try await Self.lookUp(
            "Lib.Item",
            lib: "public struct Item { public init() {} }\n",
            other: """
            import Lib

            // Another module's type of the same name, nested, and an extension of it.

            public struct Holder {
                public struct Item {
                    let base: [Item] = []; let top: Lib.Item? = nil
                }
            }

            extension Holder.Item { func convert() -> Item { Item() } }

            extension Item: CustomStringConvertible { public var description: String { "" } }
            """
        )

        #expect(!output.contains("no use spelled"), "\(output)")
        #expect(output.contains("\"Item\" used by 3 lines in 1 file — "), "\(output)")
        #expect(output.contains("; 1 extension in another module counted as use — deleting the type breaks that module"), "\(output)")
        #expect(output.contains("\n  Sources/Other/Ext.swift (3):\n    :7  | let base: [Item] = []; let top: Lib.Item? = nil\n    :11  | extension Holder.Item { func convert() -> Item { Item() } }\n    :13  | extension Item: CustomStringConvertible { public var description: String { \"\" } }"), "\(output)")
    }

    /// A bare name an enclosing generic parameter list binds is that parameter, never the type: only the lines naming the type itself are its uses.
    @Test
    func aGenericParameterOfTheSameNameIsNotAUse() async throws {
        let output = try await Self.lookUp(
            "Shadowed",
            lib: "public struct Shadowed {}\n",
            other: """
            import Lib

            func shadow<Shadowed>(_ x: Shadowed) -> Shadowed { x }
            struct Box<Shadowed> { let value: Shadowed }
            func meta<Shadowed>(_: Shadowed) -> Any { Shadowed.self }
            let real: Shadowed? = nil
            func qualified<Shadowed>(_ x: Shadowed) -> Lib.Shadowed? { nil }
            """
        )

        #expect(output.contains("\"Shadowed\" used by 2 lines in 1 file — "), "\(output)")
        #expect(output.contains("\n  Sources/Other/Ext.swift (2):\n    :6  | let real: Shadowed? = nil\n    :7  | func qualified<Shadowed>(_ x: Shadowed) -> Lib.Shadowed? { nil }"), "\(output)")
    }

    /// Each written form that names a type, on a line of its own, is one use of it: conformance, existential and opaque types, a collection or optional around it, a key path, a metatype and an attribute.
    @Test(arguments: [
        ("public protocol Gizmo {}", "struct Crate: Gizmo {}"),
        ("public protocol Gizmo {}", "func take(_ item: any Gizmo) {}"),
        ("public protocol Gizmo {}", "func make() -> some Gizmo { fatalError() }"),
        ("public struct Gizmo {}", "let items: [Gizmo] = []"),
        ("public struct Gizmo {}", "let items: Set<Gizmo>? = nil"),
        ("public struct Gizmo {}", "let item: Gizmo? = nil"),
        ("public struct Gizmo { public var size = 1 }", "let path = \\Gizmo.size"),
        ("public struct Gizmo {}", "let kind: Gizmo.Type = Gizmo.self"),
        ("@propertyWrapper public struct Gizmo { public var wrappedValue = 0; public init() {} }", "struct Crate { @Gizmo var size: Int }"),
    ])
    func eachWrittenFormOfATypeIsListedAsAUse(declaration: String, use: String) async throws {
        let output = try await Self.lookUp("Gizmo", lib: declaration + "\n", other: "import Lib\n\n" + use + "\n")

        #expect(!output.contains("no use spelled"), "\(output)")
        #expect(output.contains("\"Gizmo\" used by 1 line in 1 file — "), "\(output)")
        #expect(output.contains("\n  Sources/Other/Ext.swift (1):\n    :3  | \(use)"), "\(output)")
    }

    /// `where` over a two-target package, `Lib` and `Other` (which depends on it), holding `lib` and `other`, committed and never built, so the store is absent.
    private static func lookUp(_ symbol: String, lib: String, other: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Pkg", targets: [.target(name: "Lib"), .target(name: "Other", dependencies: ["Lib"])])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(lib, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.write(other, to: "Sources/Other/Ext.swift", in: root)
        try TestSources.commitAll(in: root, message: "two-target fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }
}
