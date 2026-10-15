//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the name-matched stand-in for a type: it applies the same cap to the uses the conformers block does not list, and says "listed" or "counted" of the store's lines according to what the store's own block did with them.
@Suite(.temporaryDirectories, .serialized)
struct WhereStandInListsFewUsesTests {
    /// A one-module package declaring `protocol Shape` with `conformers` conformers, used on `uses` lines, and nothing built, so the answer is the no-store stand-in's.
    private static func shapeAnswer(conformers: Int, uses: Int) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("protocol Shape {}\n", to: "Sources/Lib/Shape.swift", in: root)
        try TestSources.write((1 ... conformers).map { "struct Conformer\($0): Shape {}\n" }.joined(), to: "Sources/Lib/Conformers.swift", in: root)
        try TestSources.write((1 ... uses).map { "func use\($0)(_ shape: Shape) {}\n" }.joined(), to: "Sources/Lib/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: "Shape", freshness: engine.ensureFresh(), options: WhereOptions())
    }

    /// Four conformers and four uses: the rows hold the four uses, the conformers block the four conformances, and no conformance line is in both.
    @Test
    func aConformanceLineIsInTheConformersBlockAndNotTheRows() async throws {
        let output = try await Self.shapeAnswer(conformers: 4, uses: 4)

        #expect(output.contains("4 of them the conformances listed below"), "\(output)")
        #expect(output.contains("Sources/Lib/Uses.swift (4):"), "\(output)")
        #expect(output.contains(":1  | func use1(_ shape: Shape) {}"), "\(output)")
        #expect(!output.contains("| struct Conformer1: Shape {}"), "\(output)")
        #expect(!output.contains("Sources/Lib/Conformers.swift ("), "\(output)")
        #expect(!output.contains("where --refs Shape lists them"), "\(output)")
        #expect(output.contains("conformers of Shape (4"), "\(output)")
    }

    /// The conformances do not count against the cap: exactly eight uses beside four conformers are listed.
    @Test
    func exactlyEightUsesBesideConformersAreListed() async throws {
        let output = try await Self.shapeAnswer(conformers: 4, uses: 8)

        #expect(output.contains("Sources/Lib/Uses.swift (8):"), "\(output)")
        #expect(!output.contains("where --refs Shape lists them"), "\(output)")
    }

    /// Nine uses keep the pointer and list none, conformers or not.
    @Test
    func nineUsesKeepThePointer() async throws {
        let output = try await Self.shapeAnswer(conformers: 4, uses: 9)

        #expect(output.contains("where --refs Shape lists them"), "\(output)")
        #expect(!output.contains("Sources/Lib/Uses.swift ("), "\(output)")
    }

    /// A built package with `Net.Item` in three modules, Gamma writing `Alpha.Net.Item` on `alpha` lines, `Beta.Net.Item` on `beta` lines and `Delta.Net.Item` on one.
    ///
    /// Delta's file is then edited so the store refuses it and its stand-in scans the name. The answer is the plain one, every owner kept.
    private static func standInAnswer(alpha: Int, beta: Int) async throws -> String {
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
                    .target(name: "Delta"),
                    .target(name: "Gamma", dependencies: ["Alpha", "Beta", "Delta"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        for module in ["Alpha", "Beta", "Delta"] {
            try TestSources.write("public enum Net {\n    public struct Item {\n        public init() {}\n    }\n}\n", to: "Sources/\(module)/Net.swift", in: root)
        }
        // The first Alpha line writes Delta's as well, so the stand-in has a use of its own and the store's lines are one fewer.
        let uses = (0 ..< alpha).map { "public func a\($0)(_ item: Alpha.Net.Item\($0 == 0 ? ", _ other: Delta.Net.Item" : "")) {}\n" }
            + (0 ..< beta).map { "public func b\($0)(_ item: Beta.Net.Item) {}\n" }
            + (alpha == 0 ? ["public func d(_ item: Delta.Net.Item) {}\n"] : [])
        try TestSources.write("import Alpha\nimport Beta\nimport Delta\n\n" + uses.joined(), to: "Sources/Gamma/Use.swift", in: root)
        try TestSources.commitAll(in: root, message: "stand-in fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public enum Net {\n    public struct Item {\n        public init() {}\n        public var edited: Int { 1 }\n    }\n}\n", to: "Sources/Delta/Net.swift", in: root)
        let path = root.appendingPathComponent("Sources/Delta/Net.swift").path
        let current = try (FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: path)
        let freshness = try await engine.ensureFresh()
        let options = WhereOptions(includeReferences: false, collapsesSeveralOwners: false, standsInForSearch: false)
        return try await engine.lookup(symbol: "Net.Item", freshness: freshness, options: options)
    }

    /// Nine lines write `Alpha.Net.Item`, one of them `Delta.Net.Item` too: the store's block counts its nine with the pointer and no rows, and the eight left after Delta's own are counted, though eight is within the cap.
    @Test
    func linesTheStoreOnlyCountedAreSaidToBeCounted() async throws {
        let output = try await Self.standInAnswer(alpha: 9, beta: 0)

        #expect(output.contains("8 more lines the index store resolved to another declaration of the name, counted above under it, so not use"), "\(output)")
        #expect(!output.contains("listed above under it"), "\(output)")
    }

    /// Two store blocks of five lines each are both listed, though their sum passes the cap.
    @Test
    func linesTwoStoreBlocksListedAreSaidToBeListed() async throws {
        let output = try await Self.standInAnswer(alpha: 5, beta: 5)

        #expect(output.contains("9 more lines the index store resolved to another declaration of the name, listed above under it, so not use"), "\(output)")
        #expect(!output.contains("counted above under it"), "\(output)")
    }

    /// One block listed and one counted: both are said, with how many each.
    @Test
    func aMixOfListedAndCountedLinesSaysBoth() async throws {
        let output = try await Self.standInAnswer(alpha: 9, beta: 3)

        #expect(output.contains("11 more lines the index store resolved to another declaration of the name, 3 listed above under it, 8 counted, so not use"), "\(output)")
    }

    /// An extension qualified by another module's name is no use of the tree's `Alpha.Box`, so the stand-in neither counts nor lists it, while a bare use and an `Alpha`-qualified one are listed.
    @Test
    func anOtherModuleQualifiedWrittenNameIsNeitherListedNorCounted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Pair", targets: [
                .target(name: "Alpha", path: "Sources/Alpha"),
                .target(name: "Delta", path: "Sources/Delta"),
                .target(name: "Epsilon", dependencies: ["Alpha"], path: "Sources/Epsilon"),
            ])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Box<Element> {}\n\nfunc bare(_ box: Box<Int>) {}\n", to: "Sources/Alpha/Box.swift", in: root)
        try TestSources.write("import Shelf\n\nextension Shelf.Box<Int> {\n    func shelf() {}\n}\n", to: "Sources/Delta/Shelf.swift", in: root)
        try TestSources.write("import Alpha\n\nfunc own(_ box: Alpha.Box<Int>) {}\n", to: "Sources/Epsilon/Own.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Alpha.Box", freshness: engine.ensureFresh(), options: WhereOptions())

        #expect(!output.contains("Shelf"), "\(output)")
        #expect(output.contains("2 uses by written name in 2 files"), "\(output)")
        #expect(output.contains("| func bare(_ box: Box<Int>) {}"), "\(output)")
        #expect(output.contains("| func own(_ box: Alpha.Box<Int>) {}"), "\(output)")
    }
}
