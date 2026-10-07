//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that a walked row is never left out where no index store can speak for it, whatever qualifier its clause writes, and that the store's refutation of a row stops once the row's file changes after the build.
@Suite(.temporaryDirectories, .serialized)
struct WhereInheritedKeepTests {
    /// The module that subclasses the classes the second module makes conform, behind the first module's name, its owner's, or a typealias.
    static var app: String {
        """
        import Kit
        import Lib

        typealias R13 = Lib.Outer13.Inner
        class S13: Lib.Outer13.Inner {}
        class S13b: S13 {}
        class S13c: Outer13.Inner {}
        class S13d: R13 {}
        class S14: Lib.Outer14.Inner14 {}
        class S14b: S14 {}

        """
    }

    /// The rows each protocol lists, in every mode: a class declared in an extension of its owner, reached by spelling the owner with its module, bare, and through an alias, and a nested class extended through an alias of its owner.
    static var expected: [String: [String]] {
        [
            "P13": [
                "Kit.Outer13.Inner — extension — Sources/Kit/Kit.swift:6",
                "App.S13 — class — Sources/App/App.swift:5 — inherited through Inner",
                "App.S13c — class — Sources/App/App.swift:7 — inherited through Inner",
                "App.S13d — class — Sources/App/App.swift:8 — inherited through R13",
                "App.S13b — class — Sources/App/App.swift:6 — inherited through S13",
            ],
            "P14": [
                "Kit.O14.Inner14 — extension — Sources/Kit/Kit.swift:7",
                "App.S14 — class — Sources/App/App.swift:9 — inherited through Inner14",
                "App.S14b — class — Sources/App/App.swift:10 — inherited through S14",
            ],
        ]
    }

    /// Writes a package of three modules: a class nested in an extension of its owner and one nested in its owner's body, declared in the first, made to conform in the second, and subclassed in the third.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                    .target(name: "Kit", dependencies: ["Lib"]),
                    .target(name: "App", dependencies: ["Lib", "Kit"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            "public enum Outer13 {}\nextension Lib.Outer13 {\n    open class Inner {}\n}\npublic enum Outer14 {\n    open class Inner14 {}\n}\n",
            to: "Sources/Lib/Lib.swift",
            in: root
        )
        try TestSources.write(
            "import Lib\n\npublic protocol P13 {}\npublic protocol P14 {}\ntypealias O14 = Outer14\nextension Outer13.Inner: P13 {}\nextension O14.Inner14: P14 {}\n",
            to: "Sources/Kit/Kit.swift",
            in: root
        )
        try TestSources.write(app, to: "Sources/App/App.swift", in: root)
    }

    /// The package above, built once for the suite.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-inherited-keep") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "inherited keep fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The rows under `symbol`'s conformers caption in `output`, with the store's caption or the written name's.
    private static func rows(_ symbol: String, in output: String) -> [String] {
        WhereConformersOnceTests.rowsUnder("conformers of \(symbol) (", in: output)
    }

    /// The store's marks on `rows`: each listed row is direct, each walked row as it was.
    private static func marked(_ rows: [String]) -> [String] {
        rows.map { $0.contains(" — inherited through ") ? $0 : $0 + " — direct" }
    }

    /// Without the store, every subclass of both nested classes is listed, whatever qualifier its clause writes.
    @Test
    func withoutTheStoreEverySubclassIsListed() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P13", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))
            let nested = try await engine.lookup(symbol: "P14", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            #expect(Self.rows("P13", in: output) == Self.expected["P13"], "\(output)")
            #expect(Self.rows("P14", in: nested) == Self.expected["P14"], "\(nested)")
        }
    }

    /// With the store, files unchanged since the build, the same subclasses are listed, since the store records each inheriting from the protocol.
    @Test
    func withTheStoreEverySubclassIsListed() async throws {
        try await Self.fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: "P13", freshness: engine.ensureFresh())
            let nested = try await engine.lookup(symbol: "P14", freshness: engine.ensureFresh())

            #expect(Self.rows("P13", in: output) == Self.marked(Self.expected["P13"] ?? []), "\(output)")
            #expect(Self.rows("P14", in: nested) == Self.marked(Self.expected["P14"] ?? []), "\(nested)")
        }
    }

    /// With the store, once the subclasses' file changes after the build, the store cannot speak for them, and every one is still listed.
    @Test
    func aSubclassInAFileChangedSinceTheBuildIsListed() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "changed subclass fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(Self.app + "\n", to: "Sources/App/App.swift", in: root)

        let output = try await engine.lookup(symbol: "P13", freshness: engine.ensureFresh())
        let nested = try await engine.lookup(symbol: "P14", freshness: engine.ensureFresh())

        #expect(Self.rows("P13", in: output) == Self.marked(Self.expected["P13"] ?? []), "\(output)")
        #expect(Self.rows("P14", in: nested) == Self.marked(Self.expected["P14"] ?? []), "\(nested)")
    }

    /// Pins the liveness check on the store's refutation: with the store, a subclass of a nested class of the walked name is left out, and listed again once its file changes after the build, in a protocol's block and in a class's block by written name alike.
    ///
    /// Both blocks list the subclass again only because the store is not asked of a row in a file changed since the build; the walk's rule on which parents the store vouches for is not what this exercises.
    @Test
    func theStoresRefutationStopsOnceTheRowsFileChanges() async throws {
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
        let nest = "public enum NS {\n    open class Base {}\n    open class Wrong: Base {}\n    open class Stem {}\n    open class Twig: Stem {}\n}\n"
        try TestSources.write("public protocol P {}\nopen class Base: P {}\nopen class Root {}\nopen class Stem: Root {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write(nest, to: "Sources/Lib/Nest.swift", in: root)
        try TestSources.commitAll(in: root, message: "refuted row fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let built = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh())
        let builtRoot = try await engine.lookup(symbol: "Root", freshness: engine.ensureFresh())
        try TestSources.write(nest + "\n", to: "Sources/Lib/Nest.swift", in: root)

        let changed = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh())
        let changedRoot = try await engine.lookup(symbol: "Root", freshness: engine.ensureFresh())
        let wrong = "Lib.NS.Wrong — class — Sources/Lib/Nest.swift:3 — inherited through Base"
        let twig = "Lib.NS.Twig — class — Sources/Lib/Nest.swift:5 — inherited through Stem"

        #expect(Self.rows("P", in: built) == ["Lib.Base — class — Sources/Lib/Base.swift:2 — direct"], "\(built)")
        #expect(Self.rows("P", in: changed) == ["Lib.Base — class — Sources/Lib/Base.swift:2 — direct", wrong], "\(changed)")
        #expect(!builtRoot.contains("Twig"), "\(builtRoot)")
        #expect(WhereConformersOnceTests.rowsUnder("conformers of Root (2, by written name, 1 inherited — ", in: changedRoot) == [
            "Lib.Stem — class — Sources/Lib/Base.swift:4",
            twig,
        ], "\(changedRoot)")
    }

    /// With the store, a subclass written through a typealias is still listed through a second listed class of the walked name the store cannot speak for, after the store refuted it through the first.
    @Test
    func anAliasRefutedThroughOneParentIsWalkedThroughAnother() async throws {
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
        try TestSources.write("public protocol P {}\nopen class Base: P {}\n", to: "Sources/Lib/A.swift", in: root)
        try TestSources.write("public enum NS {\n    open class Base {}\n}\n", to: "Sources/Lib/B.swift", in: root)
        try TestSources.write("public typealias R = NS.Base\npublic final class S: R {}\n", to: "Sources/Lib/C.swift", in: root)
        try TestSources.commitAll(in: root, message: "alias through two parents fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public enum NS {\n    open class Base: P {}\n}\n", to: "Sources/Lib/B.swift", in: root)

        let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh())

        #expect(Self.rows("P", in: output).last == "Lib.S — class — Sources/Lib/C.swift:2 — inherited through R", "\(output)")
    }
}
