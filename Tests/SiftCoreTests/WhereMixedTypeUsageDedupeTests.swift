//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a `where <Type>` answer that mixes a row the index store answered with one it refused, against a really built store: the refused row's name-matched sites never repeat a site the store's row already listed.
@Suite(.temporaryDirectories)
struct WhereMixedTypeUsageDedupeTests {
    /// Two modules each declaring an `Item`, and a third using both: one line naming each, and two lines naming only `Alpha`'s, one of them twice.
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Mixed",
                targets: [
                    .target(name: "Alpha"),
                    .target(name: "Beta"),
                    .target(name: "Gamma", dependencies: ["Alpha", "Beta"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        for module in ["Alpha", "Beta"] {
            try TestSources.write(
                """
                public struct Item {
                    public init() {}
                }
                """,
                to: "Sources/\(module)/Item.swift",
                in: root
            )
        }
        try TestSources.write(
            """
            import Alpha
            import Beta

            public func pair(_ first: Alpha.Item, _ second: Beta.Item) {}

            public func single(_ only: Alpha.Item) {}

            public func make() -> Alpha.Item { Alpha.Item() }
            """,
            to: "Sources/Gamma/Use.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "mixed fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// Nudges a file's mtime forward so an edit made microseconds after the last stat still reads as a change.
    private static func bumpMtime(of relativePath: String, in root: URL) throws {
        let path = root.appendingPathComponent(relativePath).path
        let current = try (FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: path)
    }

    /// `Alpha.Item` is answered by the store and `Beta.Item` refused as modified since the build, so `Beta.Item`'s stand-in scans every written `Item`: a line only `Alpha.Item` is written on is the store's, listed above, and is counted rather than listed again, while the line writing both keeps its `Beta.Item` — the match is by the column the name is written at, never the line.
    ///
    /// Run with the usage listing (a caller keeping every owner's uses) and with the `--refs` sweep, which is how a bare name several modules declare reaches this answer at all, since it lists the lines where the usage verdict does not.
    @Test(arguments: [false, true])
    func aRefusedRowsNameMatchedSitesDoNotRepeatTheStoresListing(sweep: Bool) async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(
            """
            public struct Item {
                public init() {}
                public var edited: Int { 1 }
            }
            """,
            to: "Sources/Beta/Item.swift",
            in: root
        )
        try Self.bumpMtime(of: "Sources/Beta/Item.swift", in: root)
        let freshness = try await engine.ensureFresh()

        let options = WhereOptions(includeReferences: sweep, collapsesSeveralOwners: false)
        let output = try await engine.lookup(symbol: "Item", freshness: freshness, options: options)

        // The mixed state itself: one row answered by the store, the other refused into the name-matched stand-in.
        #expect(output.contains("semantic REFUSED for Beta.Item"), "\(output)")
        #expect(output.contains("used by Alpha.Item: 3 references in 1 file"), "\(output)")
        #expect(output.contains("Sources/Gamma/Use.swift (3):\n    :4  | public func pair(_ first: Alpha.Item, _ second: Beta.Item) {}\n    :6  | public func single(_ only: Alpha.Item) {}\n    :8  | public func make() -> Alpha.Item { Alpha.Item() }"), "\(output)")
        let heading = try #require(output.range(of: NameMatchedSites.typeUseHeadingOpening), "\(output)")
        let standIn = String(output[heading.upperBound...])
        #expect(standIn.contains("\"Item\" used by 1 line in 1 file"), "\(standIn)")
        #expect(standIn.contains("2 more lines the index store resolved to another declaration of the name, listed above under it, so not use"), "\(standIn)")
        #expect(standIn.contains("(for Beta.Item):\n  Sources/Gamma/Use.swift (1):\n    :4  | public func pair(_ first: Alpha.Item, _ second: Beta.Item) {}"), "\(standIn)")
        #expect(!standIn.contains("6"), "\(standIn)")
    }
}
