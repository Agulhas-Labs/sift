//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query's uses by name are narrowed by receiver as its calls are: a use written inside another type, or on another type, is left out and counted, and every use that may reach the type stays listed.
@Suite(.temporaryDirectories)
struct WhereUseReceiverTests {
    private static var types: String {
        """
        struct Depot {
            private(set) var stock = 0
            static func stock(in shelf: Int) -> Int { shelf }
            struct Crate {
                func count() -> Int { stock(in: 1) }
            }
        }
        extension Depot {
            func total() -> Int { stock }
        }
        protocol Shelved {}
        extension Depot: Shelved {}
        extension Shelved {
            func peek() -> Int { stock }
        }
        """
    }

    private static var uses: String {
        """
        struct Orchard {
            func qualified() -> Int { Depot.stock(in: 3) }
            func held(_ depot: Depot) -> Int { depot.stock }
            func rooted() -> Any { \\Depot.stock }
            func implied() -> Any { \\.stock }
            func local() -> Int {
                let stock = 4
                return stock
            }
            func named() -> Int { Orchard.stock }
        }
        """
    }

    private static func answer(_ symbol: String, types: String = types) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(types, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(uses, to: "Sources/App/Uses.swift", in: root)
        try TestSources.write("_ = stock\n", to: "Sources/App/main.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup(symbol, in: root)
    }

    /// A bare use inside an unrelated type, a local there, and a use written on another type are dropped and counted on the name line.
    @Test
    func usesInsideOrOnAnotherTypeAreDroppedAndCounted() async throws {
        let output = try await Self.answer("Depot.stock")

        #expect(!output.contains("in Orchard.local()"))
        #expect(!output.contains("in Orchard.named()"))
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("\"stock\" (") })
        #expect(line.contains("2 on other types dropped, 8 kept"))
    }

    /// Uses on the type, on a receiver the scan cannot type, in key paths, and bare inside the type, its extension, a type nested in it, a conformed protocol's extension or at top level stay listed.
    @Test
    func usesThatMayReachTheTypeStayListed() async throws {
        let output = try await Self.answer("Depot.stock")
        let kept = ["Orchard.qualified()", "Orchard.held(_:)", "Orchard.rooted()", "Orchard.implied()", "Depot.Crate.count()", "Depot.total()", "Shelved.peek()"]

        #expect(output.contains("Sources/App/main.swift"))
        for function in kept {
            #expect(output.contains("in \(function)"), "\(function)")
        }
    }

    /// A type declaring only the property is narrowed by its own declaration: its extension's bare use stays listed and another type's local is dropped.
    @Test
    func aPropertyAloneNarrowsByItsType() async throws {
        let output = try await Self.answer("Depot.stock", types: "struct Depot {\n    var stock = 0\n}\nextension Depot {\n    func total() -> Int { stock }\n}\n")

        #expect(output.contains("in Depot.total()"))
        #expect(output.contains("in Orchard.held(_:)"))
        #expect(!output.contains("in Orchard.local()"))
    }
}
