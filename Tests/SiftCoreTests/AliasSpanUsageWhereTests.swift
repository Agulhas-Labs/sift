//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two things a typealias declaration's *line span* cannot settle on its own, both of which put a false or misleading number into the one sentence a deletion is decided from.
///
/// A span holding a reference to the type is how the fold finds an alias, and it is nearly enough: an alias's underlying type is the only thing its declaration says. Nearly, because a span is measured in whole lines, so a second declaration on the same line lands inside it. And an alias that genuinely names the type is still not something *using* it.
@Suite(.temporaryDirectories)
struct AliasSpanUsageWhereTests {
    /// A fixture for the two things an alias declaration's *span* cannot settle on its own: `Holder.Inner` shares a line with a use of `Shadow` and names `Int`, and `Dead` is named by two aliases nothing else touches.
    private static func makeSpannedAliasRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        // The semicolon is the whole point: `Inner`'s declaration span is the line the use of `Shadow` stands on.
        try TestSources.write(
            """
            public struct Shadow {
                public init() {}
            }

            public struct Holder {
                public typealias Inner = Int; public var seen: Shadow?

                public init() {}
            }

            public func reach(_ value: Holder.Inner) -> Int { value }
            """,
            to: "Sources/Lib/Shadow.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Other {
                public init() {}
            }

            public struct Dead {
                public init() {}
            }

            public typealias Spare = Dead
            public typealias Couple = (Dead, Other)
            """,
            to: "Sources/Lib/Dead.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "spanned alias fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// An alias whose span merely *holds* a reference to the type, while its own declaration names `Int`, was folded in — and the verdict then said a line breaks when `Shadow` is deleted that does not, in the sentence a deletion is decided from.
    @Test
    func anAliasThatNamesTheTypeNowhereIsNotFoldedIn() async throws {
        let root = try Self.makeSpannedAliasRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Shadow", freshness: freshness)

        // Only `public var seen: Shadow?` uses it. `reach(_ value: Holder.Inner)` is a use of `Int`.
        #expect(output.contains("used by Lib.Shadow: 1 reference in 1 file — 1 production · 0 tests"))
        #expect(!output.contains("typealias naming it"))
        #expect(!output.contains("Holder.Inner"), "\(output)")
    }

    /// A type named only by its own aliases answered `2 references in 1 file — 2 production`, and an agent reading `2 production` leaves dead code in place: an alias is another name for the type, not something using it.
    @Test
    func aTypeOnlyItsOwnAliasesNameIsNotCountedAsUsed() async throws {
        let root = try Self.makeSpannedAliasRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Dead", freshness: freshness)

        #expect(!output.contains("2 production"), "\(output)")
        #expect(output.contains("no uses of Lib.Dead recorded in the store"), "\(output)")
        // The finding is its own, not "nothing references it" and not "it only spells its own name": the deletion it
        // clears takes the two aliases with it, which is what a reader has to be told.
        #expect(output.contains("every reference recorded is the type declaring itself or a typealias declaration naming it"))
        #expect(output.contains("nothing uses those aliases either, so they go with it"))
    }
}
