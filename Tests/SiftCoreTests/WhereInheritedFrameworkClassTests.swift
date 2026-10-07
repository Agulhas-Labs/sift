//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins which rows the inherited-conformer walk keeps: a subclass of a class from outside the tree that an extension makes conform is reached, and a row whose clause names another type of the walked name is left out, with its own subclasses, where the index store refutes it or its qualifier names another owner.
@Suite(.temporaryDirectories, .serialized)
struct WhereInheritedFrameworkClassTests {
    /// A built package of two modules: an extension of a Foundation class and its subclasses, a class conformer beside a nested class of the same name, a struct extended to conform beside an unrelated class of its name in the other module, and a nested protocol beside another of its name.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-inherited-framework-class") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib"), .target(name: "App")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                import Foundation

                public protocol Framed {}
                extension NSObject: Framed {}
                open class Home: NSObject {}
                public final class Sub: Home {}
                """,
                to: "Sources/Lib/Framed.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Plain {}
                open class Base: Plain {}
                public final class Kept: Base {}
                public enum Nest {
                    open class Base {}
                    open class Wrong: Base {}
                }
                public final class Wronger: Nest.Wrong {}
                """,
                to: "Sources/Lib/Plain.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Marked {}
                public struct Thing {}
                extension Thing: Marked {}
                """,
                to: "Sources/Lib/Marked.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Shelved {}
                public enum Shelf {
                    public protocol Delegate: Shelved {}
                }
                public enum Other {
                    public protocol Delegate {}
                }
                public final class Related: Shelf.Delegate {}
                public final class Unrelated: Other.Delegate {}
                open class Stray: Other.Delegate {}
                public final class Strays: Stray {}
                extension Shelf {
                    public final class Inner: Delegate {}
                }
                extension Other {
                    public final class Local: Delegate {}
                }
                """,
                to: "Sources/Lib/Shelved.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Spelled {}
                public typealias Spelling = Spelled
                public protocol Refined: Spelling {}
                public struct Zed: Refined {}
                public protocol Worded {}
                public enum Book {
                    public protocol Word: Worded {}
                }
                public enum Alias {
                    public typealias Word = Book.Word
                }
                public final class Aliased: Alias.Word {}
                """,
                to: "Sources/Lib/Spelled.swift",
                in: root
            )
            try TestSources.write(
                """
                open class Thing {}
                open class Cub: Thing {}
                public final class Bear: Cub {}
                """,
                to: "Sources/App/App.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "inherited framework class fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The merged block's rows for `symbol` once the store has loaded, with the caption's opening asserted.
    private static func storeRows(_ symbol: String, caption: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
        try await fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
            #expect(output.contains(caption), "\(output)", sourceLocation: sourceLocation)
            return WhereConformersOnceTests.rowsUnder("conformers of \(symbol) (", in: output)
        }
    }

    /// The written-name block's rows for `symbol` with the store set aside.
    private static func writtenNameRows(_ symbol: String) async throws -> [String] {
        try await fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))
            return WhereConformersOnceTests.rowsUnder("conformers of \(symbol) (", in: output)
        }
    }

    /// With the store, a subclass of a Foundation class an extension makes conform is listed, and its own subclass after it.
    @Test
    func theStoreListsTheSubclassesOfAnExtendedFrameworkClass() async throws {
        let rows = try await Self.storeRows("Framed", caption: "conformers of Framed (3: 1 direct, 0 indirect, 2 inherited — ")

        #expect(rows == [
            "Lib.NSObject — extension — Sources/Lib/Framed.swift:4 — direct",
            "Lib.Home — class — Sources/Lib/Framed.swift:5 — inherited through NSObject",
            "Lib.Sub — class — Sources/Lib/Framed.swift:6 — inherited through Home",
        ], "\(rows)")
    }

    /// Without the store, the same subclasses are listed through the extended class the tree does not declare.
    @Test
    func withoutTheStoreTheSubclassesAreListedToo() async throws {
        let rows = try await Self.writtenNameRows("Framed")

        #expect(rows == [
            "Lib.NSObject — extension — Sources/Lib/Framed.swift:4",
            "Lib.Home — class — Sources/Lib/Framed.swift:5 — inherited through NSObject",
            "Lib.Sub — class — Sources/Lib/Framed.swift:6 — inherited through Home",
        ], "\(rows)")
    }

    /// Without a store, an extension of a type the tree does not declare reaches only a class that writes it first, so a raw-value enum and a class writing it after its superclass are not listed.
    @Test
    func anUndeclaredExtendedTypeReachesOnlyTheClassWritingItFirst() async throws {
        let source = """
        protocol Spoken {}
        extension String: Spoken {}
        extension Outside: Spoken {}
        enum Raw: String { case one }
        class Base {}
        class Later: Base, Outside {}
        class Home: Outside {}
        class Sub: Home {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Spoken", source: source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Spoken (4, by written name, 2 inherited — ", in: output) == [
            "Sources.String — extension — Sources/Lib/Lib.swift:2",
            "Sources.Outside — extension — Sources/Lib/Lib.swift:3",
            "Sources.Home — class — Sources/Lib/Lib.swift:7 — inherited through Outside",
            "Sources.Sub — class — Sources/Lib/Lib.swift:8 — inherited through Home",
        ], "\(output)")
    }

    /// With the store, a subclass of a nested class of the walked name is left out, and so is its own subclass, while the conformer's own subclass stays.
    @Test
    func theStoreLeavesOutASubclassOfANestedClassOfTheName() async throws {
        let rows = try await Self.storeRows("Plain", caption: "conformers of Plain (2: 1 direct, 0 indirect, 1 inherited — ")

        #expect(rows == [
            "Lib.Base — class — Sources/Lib/Plain.swift:2 — direct",
            "Lib.Kept — class — Sources/Lib/Plain.swift:3 — inherited through Base",
        ], "\(rows)")
    }

    /// With the store, a subclass of an unrelated class named as the extended struct is left out, and so is its own subclass.
    @Test
    func theStoreLeavesOutASubclassOfAnUnrelatedClassOfTheName() async throws {
        let rows = try await Self.storeRows("Marked", caption: "conformers of Marked (1: 1 direct, 0 indirect — ")

        #expect(rows == ["Lib.Thing — extension — Sources/Lib/Marked.swift:3 — direct"], "\(rows)")
    }

    /// With the store, a conformer of another nested protocol of the walked name is left out, its subclass with it, and the true conformers stay, a bare clause among them.
    @Test
    func theStoreLeavesOutAConformerOfAnotherProtocolOfTheName() async throws {
        let rows = try await Self.storeRows("Shelved", caption: "conformers of Shelved (3: 1 direct, 0 indirect, 2 inherited — ")

        #expect(rows == [
            "Lib.Shelf.Delegate — protocol — Sources/Lib/Shelved.swift:3 — direct",
            "Lib.Related — class — Sources/Lib/Shelved.swift:8 — inherited through Delegate",
            "Lib.Shelf.Inner — class — Sources/Lib/Shelved.swift:13 — inherited through Delegate",
        ], "\(rows)")
    }

    /// Without the store, a clause qualifying the walked name with another owner is kept, its subclass with it, and so is a bare clause naming the other protocol: only the store's word leaves a walked row out.
    @Test
    func withoutTheStoreAnotherOwnersQualifierIsKept() async throws {
        let rows = try await Self.writtenNameRows("Shelved")

        #expect(rows == [
            "Lib.Shelf.Delegate — protocol — Sources/Lib/Shelved.swift:3",
            "Lib.Related — class — Sources/Lib/Shelved.swift:8 — inherited through Delegate",
            "Lib.Unrelated — class — Sources/Lib/Shelved.swift:9 — inherited through Delegate",
            "Lib.Stray — class — Sources/Lib/Shelved.swift:10 — inherited through Delegate",
            "Lib.Shelf.Inner — class — Sources/Lib/Shelved.swift:13 — inherited through Delegate",
            "Lib.Other.Local — class — Sources/Lib/Shelved.swift:16 — inherited through Delegate",
            "Lib.Strays — class — Sources/Lib/Shelved.swift:11 — inherited through Stray",
        ], "\(rows)")
    }

    /// Without a store, a qualifier that spells the listed protocol's owner, the module included, or that the tree declares only a typealias under, keeps the row, and so does one spelling another owner.
    @Test
    func withoutAStoreAQualifierThatMayMeanTheListedTypeKeepsTheRow() async throws {
        let source = """
        protocol Shelved {}
        enum Shelf { protocol Delegate: Shelved {} }
        enum Other { protocol Delegate {} }
        enum Alias { typealias Delegate = Shelf.Delegate }
        class Moduled: Sources.Shelf.Delegate {}
        class Aliased: Alias.Delegate {}
        class Unrelated: Other.Delegate {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Shelved", source: source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Shelved (4, by written name, 3 inherited — ", in: output) == [
            "Sources.Shelf.Delegate — protocol — Sources/Lib/Lib.swift:2",
            "Sources.Moduled — class — Sources/Lib/Lib.swift:5 — inherited through Delegate",
            "Sources.Aliased — class — Sources/Lib/Lib.swift:6 — inherited through Delegate",
            "Sources.Unrelated — class — Sources/Lib/Lib.swift:7 — inherited through Delegate",
        ], "\(output)")
    }

    /// With the store, a conformer of a protocol listed through a typealias, and a class writing the walked name through a typealias of it, are both listed, since the store records such a step against the alias.
    @Test
    func aStepThroughATypealiasKeepsTheRow() async throws {
        let spelled = try await Self.storeRows("Spelled", caption: "conformers of Spelled (2: ")
        let worded = try await Self.storeRows("Worded", caption: "conformers of Worded (2: 1 direct, 0 indirect, 1 inherited — ")

        #expect(spelled.last == "Lib.Zed — struct — Sources/Lib/Spelled.swift:4 — inherited through Refined", "\(spelled)")
        #expect(worded == [
            "Lib.Book.Word — protocol — Sources/Lib/Spelled.swift:7 — direct",
            "Lib.Aliased — class — Sources/Lib/Spelled.swift:12 — inherited through Word",
        ], "\(worded)")
    }

    /// With the store, a subclass is still listed where the class it was reached through gained the conformance after the build, since the store's record of that class is stale.
    @Test
    func aRowReachedThroughAClassChangedSinceTheBuildIsKept() async throws {
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
        try TestSources.write("public protocol Plain {}\n", to: "Sources/Lib/Plain.swift", in: root)
        try TestSources.write("open class Base {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("public final class Sub: Base {}\n", to: "Sources/Lib/Sub.swift", in: root)
        try TestSources.commitAll(in: root, message: "changed parent fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("open class Base: Plain {}\n", to: "Sources/Lib/Base.swift", in: root)

        let output = try await engine.lookup(symbol: "Plain", freshness: engine.ensureFresh())

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Plain (2: ", in: output).last == "Lib.Sub — class — Sources/Lib/Sub.swift:1 — inherited through Base", "\(output)")
    }

    /// With the store, a subclass whose clause qualifies the extended class with its own module, in a file changed since the build, is still listed with its own subclass, since the store no longer speaks for it.
    @Test
    func aRowInAFileChangedSinceTheBuildIsKept() async throws {
        let root = try TestSources.makeTempRepo()
        try WhereInheritedCrossModuleTests.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "changed walked row fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let built = try await engine.lookup(symbol: "P2", freshness: engine.ensureFresh())
        try TestSources.write(WhereInheritedCrossModuleTests.app + "\n", to: "Sources/App/App.swift", in: root)

        let changed = try await engine.lookup(symbol: "P2", freshness: engine.ensureFresh())
        let rows = [
            "Kit.Base2 — extension — Sources/Kit/Kit.swift:5 — direct",
            "App.Sub2 — class — Sources/App/App.swift:5 — inherited through Base2",
            "App.Sub3 — class — Sources/App/App.swift:7 — inherited through Root",
            "App.Sub2b — class — Sources/App/App.swift:6 — inherited through Sub2",
        ]

        #expect(WhereConformersOnceTests.rowsUnder("conformers of P2 (4: 1 direct, 0 indirect, 3 inherited — ", in: built) == rows, "\(built)")
        #expect(WhereConformersOnceTests.rowsUnder("conformers of P2 (4: 1 direct, 0 indirect, 3 inherited — ", in: changed) == rows, "\(changed)")
    }
}
