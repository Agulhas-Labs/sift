//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that a class's block by written name asks the index store of a row walked from a listed row the store refutes, where its record of that row is fresh, and keeps every row it reaches through a parent the store cannot speak for.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefutedParentTests {
    /// The second listed class of the walked name, subclassing the top-level class before the build.
    static var otherSub: String {
        "enum NS2 {\n    class Sub: Base {}\n}\n"
    }

    /// Writes a package where the nested class shares its name with a top-level one, each with subclasses, one subclassed through its own typealias and one through a typealias of a refuted subclass.
    static func writePackage(in root: URL) throws {
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
        try TestSources.write("open class Base {}\npublic enum NS {\n    open class Base {}\n}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("class Sub: Base {}\n", to: "Sources/Lib/Lead.swift", in: root)
        try TestSources.write(
            "class Sub2: Sub {}\nclass W: NS.Base {}\ntypealias RS = Sub\nclass Y: RS {}\ntypealias NB = NS.Base\nclass Z: NB {}\nclass Z2: Z {}\n",
            to: "Sources/Lib/More.swift",
            in: root
        )
        try TestSources.write(otherSub, to: "Sources/Lib/Other.swift", in: root)
        try TestSources.write("class X: NS2.Sub {}\nclass X2: X {}\n", to: "Sources/Lib/Deep.swift", in: root)
    }

    /// The package above, built once for the suite.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refuted-parent") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "refuted parent fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The package above, built in a repository of its own, its store awaited, with `file` rewritten to `contents` after the build.
    private static func changed(_ file: String, to contents: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try writePackage(in: root)
        try TestSources.commitAll(in: root, message: "changed parent fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(contents, to: file, in: root)
        return try await engine.lookup(symbol: "NS.Base", freshness: engine.ensureFresh())
    }

    /// The rows under the class's block by written name in `output`.
    private static func rows(in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let heading = lines.first(where: { $0.hasPrefix("conformers of Base (") && $0.contains(", by written name") }) else { return [] }
        return WhereConformersOnceTests.rowsUnder(heading, in: output)
    }

    /// With the store, files unchanged since the build, a subclass of a listed class the store refutes is left out, and so is one written through its typealias or reached from a second refuted class of its name, while every listed row and each row written through the asked class's own typealias stay.
    @Test
    func aSubclassOfARefutedClassIsLeftOutWithTheStore() async throws {
        try await Self.fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: "NS.Base", freshness: engine.ensureFresh())

            #expect(Self.rows(in: output) == [
                "Lib.Sub — class — Sources/Lib/Lead.swift:1",
                "Lib.W — class — Sources/Lib/More.swift:2",
                "Lib.NS2.Sub — class — Sources/Lib/Other.swift:2",
                "Lib.Z — class — Sources/Lib/More.swift:6 — through typealias Lib.NB = NS.Base",
                "Lib.Z2 — class — Sources/Lib/More.swift:7 — inherited through Z",
            ], "\(output)")
        }
    }

    /// Without the store, every subclass the walk reaches is listed, whichever class of the name it subclasses.
    @Test
    func withoutTheStoreEverySubclassIsListed() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "NS.Base", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))
            let rows = Self.rows(in: output)

            for name in ["Lib.Sub2 ", "Lib.Y ", "Lib.X ", "Lib.X2 ", "Lib.Z2 "] {
                #expect(rows.contains { $0.hasPrefix(name) }, "\(name) in \(output)")
            }
        }
    }

    /// With the store, a subclass the store refutes through one listed class is still listed through a second class of the walked name whose file changed after the build, which now subclasses the asked class.
    ///
    /// The refuted class's file sorts first, so the walk reaches the subclass through it, and has the store refute it, before it reaches it through the changed one.
    @Test
    func aSubclassRefutedThroughOneParentIsListedThroughAChangedOne() async throws {
        let output = try await Self.changed("Sources/Lib/Other.swift", to: "enum NS2 {\n    class Sub: NS.Base {}\n}\n")
        let rows = Self.rows(in: output)

        #expect(rows.contains("Lib.X — class — Sources/Lib/Deep.swift:1 — inherited through Sub"), "\(output)")
        #expect(rows.contains("Lib.X2 — class — Sources/Lib/Deep.swift:2 — inherited through X"), "\(output)")
    }

    /// With the store, once a refuted listed class's file changes after the build, the store cannot speak for it, and its subclasses are listed again.
    @Test
    func theSubclassesOfARefutedClassInAChangedFileAreListed() async throws {
        let output = try await Self.changed("Sources/Lib/Lead.swift", to: "class Sub: Base {}\n\n")
        let rows = Self.rows(in: output)

        #expect(rows.contains("Lib.Sub2 — class — Sources/Lib/More.swift:1 — inherited through Sub"), "\(output)")
        #expect(rows.contains("Lib.Y — class — Sources/Lib/More.swift:4 — inherited through RS"), "\(output)")
    }
}
