//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins three behaviours of `where` that nothing else asserts: the plain-mode wording for sites the store resolved elsewhere, the query a plain type answer points to among several same-named owners, and the spellings a build may have recorded a file under.
@Suite(.temporaryDirectories)
struct WherePinsTests {
    /// Two modules each declaring an `Item`, and a third using both: one line naming each, and two lines naming only `Alpha`'s.
    private static func makeMixedRepo() throws -> URL {
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
            try TestSources.write("public struct Item {\n    public init() {}\n}\n", to: "Sources/\(module)/Item.swift", in: root)
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

    /// The plain answer's options: the type answered with its several owners kept, and no sweep.
    private static var plain: WhereOptions {
        WhereOptions(includeReferences: false, collapsesSeveralOwners: false, standsInForSearch: false)
    }

    /// Where one row is answered by the store and the other refused into the name-matched stand-in, the plain answer says the store's lines are counted above, not listed, and names the query that lists them.
    @Test
    func aPlainStandInSaysTheStoresLinesAreCountedAbove() async throws {
        let root = try Self.makeMixedRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public struct Item {\n    public init() {}\n    public var edited: Int { 1 }\n}\n", to: "Sources/Beta/Item.swift", in: root)
        let path = root.appendingPathComponent("Sources/Beta/Item.swift").path
        let current = try (FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: path)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Item", freshness: freshness, options: Self.plain)

        #expect(output.contains("2 more lines the index store resolved to another declaration of the name, counted above under it, so not use (for Beta.Item) — where --refs Beta.Item lists them"), "\(output)")
    }

    /// Three same-named types, one nested, with nothing built: the pointer is the first row's shortest name no other declaration ends with.
    @Test
    func theNoStorePointerNamesTheShortestDistinguishingOwner() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Pointer",
                targets: [
                    .target(name: "App", path: "Sources/App"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("enum A {\n    enum Inner {\n        struct Config {}\n    }\n    struct Config {}\n}\nenum B {\n    struct Config {}\n}\nfunc use(_ first: A.Config, _ second: B.Config, _ third: A.Inner.Config) {}\n", to: "Sources/App/Types.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Config", freshness: freshness, options: Self.plain)

        #expect(output.contains("(for App.A.Config, App.A.Inner.Config, App.B.Config) — where --refs Inner.Config lists them"), "\(output)")
    }

    /// A project reached through a symlinked directory, with a build that recorded the file under the real spelling: the symlinked root's spellings reach the recorded one, and `/var` reaches `/private/var`.
    @Test
    func aUnitRecordedUnderTheRealSpellingIsReachedFromASymlinkedRoot() throws {
        let real = try TestSources.makeTempDirectory()
        let holder = try TestSources.makeTempDirectory()
        let link = holder.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try TestSources.write("struct Probe {}\n", to: "Sources/App/Probe.swift", in: real)
        let recorded = CanonicalPath.of(real.appendingPathComponent("Sources/App/Probe.swift").path)

        var spellings = FileSpellings(ofFile: "Sources/App/Probe.swift", under: link)

        #expect(spellings.first(where: { $0 == recorded }) == recorded)
        #expect(SemanticStore.spellings(ofFile: "Sources/App/Probe.swift", under: link).contains(recorded))
        var variable = FileSpellings(ofFile: "x.swift", under: URL(fileURLWithPath: "/var/folders/none"))
        #expect(variable.first(where: { $0 == "/private/var/folders/none/x.swift" }) != nil)
    }
}
