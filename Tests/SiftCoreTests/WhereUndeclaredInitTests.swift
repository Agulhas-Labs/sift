//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where T.init` for a type that declares no initializer of its own answers with the type and the places it is built.
///
/// Such a type is built through an initializer the compiler wrote or one it inherits, so no declaration sits under T for the path to find. Answered as a path that does not resolve, it listed every other type's `init` and not one of T's construction sites.
@Suite(.temporaryDirectories)
struct WhereUndeclaredInitTests {
    static var shapes: String {
        """
        class Base {
            let size: Int
            init(size: Int) { self.size = size }
        }

        final class Sub: Base {}

        struct Point {
            let x: Int
        }

        struct Depot {
            init(count: Int) {}
        }

        enum Maker {
            static func make() -> Int {
                let sub = Sub(size: 1)
                let point = Point(x: 1)
                let depot = Depot(count: 2)
                return sub.size + point.x
            }
        }
        """
    }

    static func lookup(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shapes, to: "Sources/App/Shapes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A subclass that inherits its initializers is answered with its declaration, where they come from, and its construction sites.
    @Test
    func anInheritedInitializerListsTheSubclassConstructionSites() async throws {
        let output = try await Self.lookup("Sub.init")

        #expect(!output.contains("could not resolve the path"), "\(output)")
        #expect(output.contains(".Sub — class — final class Sub: Base — Sources/App/Shapes.swift:6"), "\(output)")
        #expect(output.contains("Sub declares no init — it inherits Base's initializers"), "\(output)")
        #expect(output.contains("\"Sub.init\" (1 call site in 1 file):"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shapes.swift:18  in Maker.make().sub"), "\(output)")
        #expect(!output.contains("Depot"), "\(output)")
    }

    /// A struct with only its memberwise initializer says the compiler writes it, and lists where it is called, not every other type's init.
    @Test
    func aMemberwiseInitializerListsTheStructConstructionSites() async throws {
        let output = try await Self.lookup("Point.init")

        #expect(!output.contains("could not resolve the path"), "\(output)")
        #expect(output.contains(".Point — struct — struct Point — Sources/App/Shapes.swift:8-10"), "\(output)")
        #expect(output.contains("Point declares no init — the compiler writes its memberwise initializer"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shapes.swift:19  in Maker.make().point"), "\(output)")
        #expect(!output.contains("Base.init(size:)"), "\(output)")
        #expect(!output.contains("Depot"), "\(output)")
    }

    /// The labeled spelling of a compiler-written initializer gets the same answer, since no declaration under the type carries those labels either.
    @Test
    func aLabeledQueryForAMemberwiseInitializerIsAnsweredTheSameWay() async throws {
        let output = try await Self.lookup("Point.init(x:)")

        #expect(output.contains("Point declares no init"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shapes.swift:19  in Maker.make().point"), "\(output)")
    }

    /// A type that declares an initializer still resolves to it, with no note about one the compiler writes.
    @Test
    func aDeclaredInitializerStillResolvesToItsDeclaration() async throws {
        let output = try await Self.lookup("Depot.init")

        #expect(output.contains(".Depot.init(count:) — init"), "\(output)")
        #expect(!output.contains("declares no init"), "\(output)")
    }

    static var sameNamed: String {
        """
        struct Pod { init(top: Int) {} }

        enum Hold {
            struct Pod { var z: Int }
            static func make() -> Int {
                _ = Pod(z: 1)
                return 0
            }
        }

        func buildPod() -> Int {
            _ = Pod(top: 1)
            return 0
        }

        struct Crate { var q: Int }

        enum Shelf {
            struct Crate { init(nested: Int) {} }
        }

        func buildCrate() -> Int {
            _ = Crate(q: 1)
            return 0
        }

        protocol Plain {}

        func repod() -> Int { Sources.Pod(top: 2) }
        """
    }

    static func lookupSameNamed(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(sameNamed, to: "Sources/App/Named.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// With no index store, a qualified query keeps a site the index reads as written on a same-named type elsewhere and notes it, and keeps, flagged, one only its labels say is another's.
    @Test
    func aQualifiedQueryNotesASameNamedTypesSites() async throws {
        let output = try await Self.lookupSameNamed("Hold.Pod.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Named.swift:6  in Hold.make()"), "\(output)")
        #expect(sites.contains("Sources/App/Named.swift:12  in buildPod() (labels fit Sources.Pod)"), "\(output)")
        #expect(sites.contains("Sources/App/Named.swift:29  in repod()"), "\(output)")
        #expect(output.contains("\"Pod.init\" (3 call sites by name, 1 of them writes \"Pod\" behind a qualifier the index reads as Sources, which declares another \"Pod\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift, in 1 file):"), "\(output)")
        #expect(!output.contains("of another type named Pod dropped"), "\(output)")
    }

    /// A type declaring no init is answered beside a same-named nested type's declared one, with its own sites.
    @Test
    func aNestedSameNamedInitDoesNotHideTheTypeWithoutOne() async throws {
        let output = try await Self.lookupSameNamed("Crate.init")

        #expect(output.contains(".Shelf.Crate.init(nested:) — init"), "\(output)")
        #expect(output.contains(".Crate declares no init"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Named.swift:23  in buildCrate()"), "\(output)")
    }

    /// A protocol with no init requirement says so, and lists no other type's inits.
    @Test
    func aProtocolWithNoRequirementSaysSo() async throws {
        let output = try await Self.lookupSameNamed("Plain.init")

        #expect(output.contains("Plain declares no init requirement"), "\(output)")
        #expect(!output.contains("could not resolve the path"), "\(output)")
        #expect(!output.contains("Pod.init(top:)"), "\(output)")
    }
}
