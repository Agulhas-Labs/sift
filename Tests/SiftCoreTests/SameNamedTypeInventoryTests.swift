//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how the inventory spells a suite whose extension is written with its module's name in front.
@Suite(.temporaryDirectories)
struct SameNamedTypeInventoryTests {
    /// The suite and function of every declared test in one fixture file under the `LibTests` module.
    private static func declared(_ source: String) throws -> [String] {
        let inventory = try TestInventoryTests.inventory([("LibTests/Probe.swift", source)])
        return inventory.tests.map { "\($0.suite)/\($0.function)" }
    }

    /// A prefix naming a top-level type that shares the module's name is that type, so the declared suite keeps it.
    @Test
    func aSameNamedTypePrefixIsKeptInTheDeclaredSuite() throws {
        let declared = try Self.declared("""
        import Testing

        enum LibTests {
            struct S8 {
                @Test func z() {}
            }
        }

        extension LibTests.S8 {
            @Test func y() {}
        }
        """)

        #expect(declared.contains("LibTests.S8/y()"))
    }

    /// With no such type, the module's own name in front of the suite is dropped.
    @Test
    func aModulePrefixIsDroppedFromTheDeclaredSuite() throws {
        let declared = try Self.declared("""
        import Testing

        struct S8 {
            @Test func z() {}
        }

        extension LibTests.S8 {
            @Test func y() {}
        }
        """)

        #expect(declared.contains("S8/y()"))
    }
}
