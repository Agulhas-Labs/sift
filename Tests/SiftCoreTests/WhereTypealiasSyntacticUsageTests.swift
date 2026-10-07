//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a type's name-matched uses where the type has typealiases: an alias declaration is another name for the type rather than use of it, and what is written through the alias is.
@Suite(.temporaryDirectories)
struct WhereTypealiasSyntacticUsageTests {
    /// `Crate = Gizmo` and `Box = Crate` are counted apart in the store's words, and the lines writing either alias are listed as uses of `Gizmo`; a second site on an alias's own line stays a use.
    @Test
    func anAliasLineIsCountedApartAndItsUsesAreFollowed() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Gizmo {}
            public typealias Crate = Gizmo
            public typealias Box = Crate
            public typealias Spare = Gizmo; public var spare: Gizmo? = nil
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.write(
            """
            func make() -> Crate { Crate() }
            let boxed: Box? = nil
            let plain: Gizmo? = nil
            """,
            to: "Sources/Lib/Use.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "aliases of a type, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Gizmo", freshness: freshness)

        #expect(output.contains("\"Gizmo\" used by 4 lines in 2 files — "), "\(output)")
        #expect(output.contains("; 2 written as Sources.Box and Sources.Crate, typealiases naming it, folded in here"), "\(output)")
        #expect(output.contains("; 2 more lines declaring a typealias of it, which is another name for the type rather than use of it"), "\(output)")
        #expect(output.contains("\n  Sources/Lib/Gizmo.swift (1):\n    :4  | public typealias Spare = Gizmo; public var spare: Gizmo? = nil\n"), "\(output)")
        #expect(output.contains("\n  Sources/Lib/Use.swift (3):\n    :1  | func make() -> Crate { Crate() }\n    :2  | let boxed: Box? = nil\n    :3  | let plain: Gizmo? = nil"), "\(output)")
    }

    /// A right-hand side with generic arguments builds a type from the name rather than naming it, so its line stays a use, and the alias's own uses, which break with the type, are folded in.
    @Test
    func aGenericRightHandSideStaysAUse() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Crate<Element> {}
            public typealias Ints = Crate<Int>
            """,
            to: "Sources/Lib/Crate.swift",
            in: root
        )
        try TestSources.write(
            """
            let many: Ints? = nil
            """,
            to: "Sources/Lib/Use.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "a generic alias of a type, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Crate", freshness: freshness)

        #expect(output.contains("\"Crate\" used by 2 lines in 2 files — "), "\(output)")
        #expect(output.contains("\n  Sources/Lib/Crate.swift (1):\n    :2  | public typealias Ints = Crate<Int>"), "\(output)")
        #expect(output.contains("\n  Sources/Lib/Use.swift (1):\n    :1  | let many: Ints? = nil"), "\(output)")
        #expect(!output.contains("declaring a typealias of it"), "\(output)")
        #expect(output.contains("1 written as Sources.Ints, a typealias naming it, folded in here"), "\(output)")
    }
}
