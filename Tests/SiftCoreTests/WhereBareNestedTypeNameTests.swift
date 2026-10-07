//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a nested type's name-matched uses where another type nests a type of the same name: a bare name written inside that other type means its own, so the line is counted apart rather than listed as a use of the type asked for.
@Suite(.temporaryDirectories)
struct WhereBareNestedTypeNameTests {
    /// `Item` written bare inside `Holder`, which declares its own `Item`, is `Holder.Item`: counted apart with the rule said, while the lines that can mean `Crate.Item` stay listed.
    @Test
    func aBareNameInsideATypeDeclaringItsOwnIsCountedApart() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Crate {
                public struct Item {}
                let items: [Item]
            }
            public struct Holder {
                public struct Item {}
                let items: [Item]
                let crated: Crate.Item? = nil
            }
            extension Holder {
                func make() -> Item { Item() }
            }
            """,
            to: "Sources/Lib/Lib.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "nested same-named types, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Crate.Item", freshness: freshness)

        #expect(output.contains("\"Item\" used by 2 lines in 1 file — "), "\(output)")
        #expect(output.contains("; 2 more lines writing \"Item\" bare inside a type that declares its own \"Item\", which is what the name means there, so not use (for "), "\(output)")
        #expect(output.contains("\n  Sources/Lib/Lib.swift (2):\n    :3  | let items: [Item]\n    :8  | let crated: Crate.Item? = nil\n") || output.hasSuffix("\n  Sources/Lib/Lib.swift (2):\n    :3  | let items: [Item]\n    :8  | let crated: Crate.Item? = nil"), "\(output)")
    }
}
