//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A name-matched `T(…)` site stays in the answer to `where T.init` whatever its labels, where only its labels say another type of the name builds it.
///
/// A type may have initializers a name scan cannot see — one an extension in another module adds, literal coercion, a macro's, one inside `#if`, one a protocol extension outside the index lends — so labels none of its known initializers take, where another same-named type's do, dropped real sites of it. They are now kept and flagged with the type the labels fit; only a written qualifier the index resolves fully to another scope leaves a site out.
@Suite(.temporaryDirectories)
struct WhereSameNameNoLabelDropTests {
    static var package: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "App", targets: [.target(name: "Lib"), .target(name: "App", dependencies: ["Lib"])])
        """
    }

    static var library: String {
        """
        public struct Vane {
            public init(size: Int) {}
        }
        """
    }

    static var probes: String {
        """
        import Lib

        extension Vane {
            init(spin: Int) { self.init(size: spin) }
        }

        enum Home {
            struct Tag: ExpressibleByStringLiteral {
                init(stringLiteral value: String) {}
            }

            @Buildable
            struct Gauge {
                var level: Int
                init() { level = 0 }
            }

            struct Dial {
                var turn: Int
                #if DEBUG
                init(probe: Int) { turn = probe }
                #endif
            }

            struct Payload: Decodable {
                let id: Int
                init() { id = 0 }
            }
        }

        extension Decodable {
            init(json: String) { fatalError() }
        }

        enum Other {
            struct Vane { init(spin: Int) {} }
            struct Tag { init(_ text: String) {} }
            struct Gauge { init(level: Int) {} }
            struct Dial { init(turn: Int) {} }
            struct Payload { init(json: String) {} }
        }

        func spinUp() -> Int {
            _ = Vane(spin: 1)
            return 0
        }

        func tagged() -> Int {
            _ = Tag("x")
            _ = Gauge(level: 3)
            _ = Dial(turn: 1)
            _ = Payload(json: "{}")
            return 0
        }

        struct Inner { var w: Int }

        enum Outer {
            struct Inner { init(v: Int) {} }
        }

        enum Holder {
            typealias Inner = Outer.Inner
        }

        func held() -> Int {
            _ = Holder.Inner(v: 9)
            return 0
        }
        """
    }

    static func lookup(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(package, to: "Package.swift", in: root)
        try TestSources.write(library, to: "Sources/Lib/Vane.swift", in: root)
        try TestSources.write(probes, to: "Sources/App/Probes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// Each site row of `output`, its indent trimmed.
    static func rows(_ output: String) -> [String] {
        WhereSameNameInitTests.rows(WhereAnswerRepetitionTests.sitesOnePerLine(output))
    }

    /// A site of an initializer an extension in another module adds is listed under the type, though another type's declared one takes its labels.
    @Test
    func aSiteOfAnotherModulesExtensionInitIsListed() async throws {
        let output = try await Self.lookup("Lib.Vane.init")

        #expect(Self.rows(output).contains("Sources/App/Probes.swift:44  in spinUp() (no declared init matches — compiler-written or inherited) (labels fit App.Other.Vane)"), "\(output)")
    }

    /// A literal coerced to an `ExpressibleByStringLiteral` type is listed under it.
    @Test
    func aLiteralCoercionSiteIsListed() async throws {
        let output = try await Self.lookup("Home.Tag.init")

        #expect(Self.rows(output).contains { $0.hasPrefix("Sources/App/Probes.swift:49  in tagged()") }, "\(output)")
    }

    /// A site of an initializer a macro attached to the type may write is listed under it.
    @Test
    func aMacroAttributedTypesSiteIsListed() async throws {
        let output = try await Self.lookup("Home.Gauge.init")

        #expect(Self.rows(output).contains { $0.hasPrefix("Sources/App/Probes.swift:50  in tagged()") }, "\(output)")
    }

    /// A site of the memberwise initializer a type has where its only declared one is inside an inactive `#if` clause is listed under it.
    @Test
    func aSiteOfAnInitInsideIfConfigIsListed() async throws {
        let output = try await Self.lookup("Home.Dial.init")

        #expect(Self.rows(output).contains { $0.hasPrefix("Sources/App/Probes.swift:51  in tagged()") }, "\(output)")
    }

    /// A site of an initializer an extension of a protocol outside the index adds is listed under the conforming type.
    @Test
    func aSiteOfAnUnindexedProtocolExtensionInitIsListed() async throws {
        let output = try await Self.lookup("Home.Payload.init")

        #expect(Self.rows(output).contains { $0.hasPrefix("Sources/App/Probes.swift:52  in tagged()") }, "\(output)")
    }

    /// A site qualified with a scope whose typealias of the name stands for the type is credited to it, unflagged.
    @Test
    func aSiteQualifiedThroughAScopesTypealiasIsCredited() async throws {
        let output = try await Self.lookup("Outer.Inner.init")

        #expect(Self.rows(output).contains("Sources/App/Probes.swift:67  in held()"), "\(output)")
        #expect(!output.contains("calling no Inner.init dropped"), "\(output)")
    }
}
