//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type with a dynamic member subscript may hand on any other type's member, so a qualified query's narrowing by receiver keeps the uses written on it or inside it.
@Suite(.temporaryDirectories)
struct WhereDynamicMemberReceiverTests {
    private static var types: String {
        """
        struct Depot {
            var stock = 0
        }
        @dynamicMemberLookup
        struct Lens {
            let depot: Depot
            subscript<T>(dynamicMember path: KeyPath<Depot, T>) -> T { depot[keyPath: path] }
            func peek() -> Int { self.stock }
        }
        @dynamicMemberLookup
        struct Box<Wrapped> {
            let wrapped: Wrapped
            subscript<T>(dynamicMember path: KeyPath<Wrapped, T>) -> T { wrapped[keyPath: path] }
        }
        @dynamicMemberLookup
        struct Crate {}
        extension Crate {
            subscript(dynamicMember name: String) -> Int { 0 }
        }
        @dynamicMemberLookup
        protocol Shelved {}
        extension Shelved {
            subscript(dynamicMember name: String) -> Int { 0 }
        }
        struct Catalogue {}
        extension Catalogue: Shelved {}
        """
    }

    private static var uses: String {
        """
        struct Orchard {
            func lensed() -> Int { Lens(depot: Depot()).stock }
            func boxed() -> Int { Box<Depot>(wrapped: Depot()).stock }
            func crated() -> Int { Crate().stock }
            func shelved() -> Int { Catalogue().stock }
            func local() -> Int {
                let stock = 4
                return stock
            }
        }
        """
    }

    private static func answer(sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(types, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(uses, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let output = try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
        #expect(!output.contains("in Orchard.local()"), "a local in an unrelated type is still dropped", sourceLocation: sourceLocation)
        return output
    }

    /// A use written on `self` inside a type with a dynamic member subscript stays listed.
    @Test
    func aUseOnSelfInsideTheTypeStaysListed() async throws {
        #expect(try await Self.answer().contains("in Lens.peek()"))
    }

    /// A use written on an instance of such a type, spelled by its name, stays listed.
    @Test
    func aUseOnTheTypeStaysListed() async throws {
        #expect(try await Self.answer().contains("in Orchard.lensed()"))
    }

    /// A generic wrapper whose dynamic member subscript reads through its parameter keeps a use written on it.
    @Test
    func aUseOnAGenericWrapperStaysListed() async throws {
        #expect(try await Self.answer().contains("in Orchard.boxed()"))
    }

    /// A dynamic member subscript declared in an extension keeps a use written on the type it extends.
    @Test
    func aSubscriptInAnExtensionKeepsTheUse() async throws {
        #expect(try await Self.answer().contains("in Orchard.crated()"))
    }

    /// A type conforming, in an extension, to a protocol whose extension declares the subscript keeps a use written on it.
    @Test
    func aConformerOfADynamicMemberProtocolKeepsTheUse() async throws {
        #expect(try await Self.answer().contains("in Orchard.shelved()"))
    }
}
