//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the walk without a store where an extension in one module makes a class of another conform: a subclass spelling the class's own module, or its owner, is reached and walked further, and so is one spelling some other declaration's owner.
@Suite(.temporaryDirectories, .serialized)
struct WhereInheritedCrossModuleTests {
    /// The source of the module that makes the classes of the first module conform, for a test that changes it.
    static var app: String {
        """
        import Kit
        import Lib

        typealias Root = Lib.Base2
        class Sub2: Lib.Base2 {}
        class Sub2b: Sub2 {}
        class Sub3: Root {}
        class Sub8: Lib.Outer8.Base {}

        """
    }

    /// Writes a package of three modules: two classes, one nested, declared in the first, extended to conform in the second, and subclassed in the third behind a qualifier naming the first, directly and through a typealias.
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
        try TestSources.write("open class Base2 {}\nopen class Outer8 {\n    open class Base {}\n}\n", to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.write(
            "import Lib\n\npublic protocol P2 {}\npublic protocol P8 {}\nextension Base2: P2 {}\nextension Outer8.Base: P8 {}\n",
            to: "Sources/Kit/Kit.swift",
            in: root
        )
        try TestSources.write(app, to: "Sources/App/App.swift", in: root)
    }

    /// The written-name block's rows for `symbol` in a committed, unbuilt repository whose files `write` puts in place.
    private static func rows(_ symbol: String, write: (URL) throws -> Void) async throws -> [String] {
        let root = try TestSources.makeTempRepo()
        try write(root)
        try TestSources.commitAll(in: root, message: "cross-module inherited fixture")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        return WhereConformersOnceTests.rowsUnder("conformers of \(symbol) (", in: output)
    }

    /// Without a store, a subclass that writes the extended class behind its own module's name is listed, with its own subclass and a subclass written through a typealias of the same spelling.
    @Test
    func withoutAStoreTheExtendedClassesModuleKeepsTheRow() async throws {
        let rows = try await Self.rows("P2", write: Self.writePackage(in:))

        #expect(rows == [
            "Kit.Base2 — extension — Sources/Kit/Kit.swift:5",
            "App.Sub2 — class — Sources/App/App.swift:5 — inherited through Base2",
            "App.Sub3 — class — Sources/App/App.swift:7 — inherited through Root",
            "App.Sub2b — class — Sources/App/App.swift:6 — inherited through Sub2",
        ], "\(rows)")
    }

    /// Without a store, a subclass that writes an extended nested class behind its module and owner is listed.
    @Test
    func withoutAStoreTheExtendedNestedClassesOwnerKeepsTheRow() async throws {
        let rows = try await Self.rows("P8", write: Self.writePackage(in:))

        #expect(rows == [
            "Kit.Outer8.Base — extension — Sources/Kit/Kit.swift:6",
            "App.Sub8 — class — Sources/App/App.swift:8 — inherited through Base",
        ], "\(rows)")
    }

    /// Without a store, a subclass qualifying the name with another module than the one whose class an extension extends is kept, since only the store can tell which class it writes.
    @Test
    func withoutAStoreAnotherModulesClassOfTheNameIsKept() async throws {
        let rows = try await Self.rows("Marked") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib"), .target(name: "App", dependencies: ["Lib"])]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public protocol Marked {}\nopen class Thing {}\nextension Thing: Marked {}\n", to: "Sources/Lib/Lib.swift", in: root)
            try TestSources.write("import Lib\n\nopen class Thing {}\nclass Cub: App.Thing {}\nclass Bear: Lib.Thing {}\n", to: "Sources/App/App.swift", in: root)
        }

        #expect(rows == [
            "Lib.Thing — extension — Sources/Lib/Lib.swift:3",
            "App.Cub — class — Sources/App/App.swift:4 — inherited through Thing",
            "App.Bear — class — Sources/App/App.swift:5 — inherited through Thing",
        ], "\(rows)")
    }

    /// Without a store, where two listed protocols share a name, a clause qualifying the name with either one's owner is kept under it.
    @Test
    func twoListedParentsOfOneNameKeepTheirQualifiedRows() async throws {
        let rows = try await Self.rows("Shelved") { root in
            try TestSources.write(
                """
                protocol Shelved {}
                enum Shelf { protocol Delegate: Shelved {} }
                enum Other { protocol Delegate: Shelved {} }
                class Related: Shelf.Delegate {}
                class Unrelated: Other.Delegate {}
                """,
                to: "Sources/Lib/Lib.swift",
                in: root
            )
        }

        #expect(rows == [
            "Sources.Shelf.Delegate — protocol — Sources/Lib/Lib.swift:2",
            "Sources.Other.Delegate — protocol — Sources/Lib/Lib.swift:3",
            "Sources.Related — class — Sources/Lib/Lib.swift:4 — inherited through Delegate",
            "Sources.Unrelated — class — Sources/Lib/Lib.swift:5 — inherited through Delegate",
        ], "\(rows)")
    }
}
