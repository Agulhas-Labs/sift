//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A receiver whose type only a framework declares may hand on any member through a dynamic member subscript the tree cannot show, so a qualified query keeps a site written on it and counts it.
@Suite(.temporaryDirectories)
struct WhereFrameworkReceiverTests {
    private static var source: String {
        """
        import Foundation
        import SwiftUI

        struct Depot {
            var stock = 0
        }
        extension Data {
            var stock: Int { count }
        }
        struct Orchard {
            func bound(_ depot: Depot) -> Int {
                Binding(get: { depot }, set: { _ in }).stock.wrappedValue
            }
            func plain() -> Int { Data().stock }
        }
        """
    }

    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
    }

    /// A use written on a framework type the tree does not declare, `Binding(…).stock`, stays listed: the binding hands on the member of the type it wraps.
    @Test
    func aUseOnAFrameworkTypeStaysListed() async throws {
        #expect(try await Self.answer().contains("in Orchard.bound(_:)"))
    }

    /// A use written on a framework type known to hand on no other type's members is still another type's, and dropped.
    @Test
    func aUseOnAPlainFrameworkTypeIsDropped() async throws {
        #expect(try await !Self.answer().contains("in Orchard.plain()"))
    }

    /// The name's line counts the site kept only because its receiver's type is outside the tree, beside the one dropped.
    @Test
    func theKeptSiteIsCountedOnTheNameLine() async throws {
        let output = try await Self.answer()
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("\"stock\" (") })

        #expect(line.contains("2 uses by name, 1 on other types dropped, 1 kept, 1 on types outside the tree"))
    }
}
