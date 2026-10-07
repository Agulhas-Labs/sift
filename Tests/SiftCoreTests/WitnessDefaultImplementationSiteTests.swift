//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With a store, a requirement's implementations list a default implementation a conformer picks up where it is written, never at the conformer's header, which is where the store records the pick.
@Suite(.temporaryDirectories, .serialized)
struct WitnessDefaultImplementationSiteTests {
    /// A built package whose base protocol's function has a default in a refining protocol's extension and whose subscript has one in its own extension, which the refining protocol restates; one conformer takes both defaults, another declares its function in its body and conforms in an extension.
    ///
    /// A second protocol's property is witnessed by the standard library's `Array.count`, by a path dependency's `Tally.count` from a hidden directory the index never covers, and by a struct's own property.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-default-implementation-site") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Gizmo",
                    dependencies: [.package(path: ".vendor/Dep")],
                    targets: [.target(name: "GizmoCore", dependencies: [.product(name: "Dep", package: "Dep")])]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Dep",
                    products: [.library(name: "Dep", targets: ["Dep"])],
                    targets: [.target(name: "Dep")]
                )
                """,
                to: ".vendor/Dep/Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Tally {
                    public init() {}

                    public var count: Int {
                        2
                    }
                }
                """,
                to: ".vendor/Dep/Sources/Dep/Tally.swift",
                in: root
            )
            try TestSources.write(
                """
                import Dep

                public protocol Counted {
                    var count: Int { get }
                }

                extension Array: Counted {}

                extension Tally: Counted {}

                public struct Own: Counted {
                    public var count: Int {
                        1
                    }
                }
                """,
                to: "Sources/GizmoCore/Counted.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Named {
                    var name: String { get }
                    func wave() -> String
                    subscript(index: Int) -> String { get }
                }

                public protocol Refined: Named {
                    subscript(index: Int) -> String { get }
                }

                extension Refined {
                    public func wave() -> String {
                        "wave"
                    }
                }

                extension Named {
                    public subscript(index: Int) -> String {
                        "slot"
                    }
                }

                public struct Depot: Refined {
                    public var name: String {
                        "depot"
                    }
                }

                public struct Crate {
                    public var name: String {
                        "crate"
                    }

                    public func wave() -> String {
                        name
                    }
                }

                extension Crate: Named {}

                public func show(_ item: some Refined) -> String {
                    item.wave() + item[1]
                }
                """,
                to: "Sources/GizmoCore/Named.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "default implementation fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The base function's implementations are the refining protocol's default and the body's own function, listed where each is written; neither conformer's header is one.
    @Test
    func aDefaultIsListedWhereItIsWritten() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Named.wave", freshness: engine.ensureFresh())

            #expect(output.contains("implementations of GizmoCore.Named.wave() (2):\n  Sources/GizmoCore/Named.swift (2):\n    :12  wave()  | public func wave() -> String {\n    :34  wave()  | public func wave() -> String {"), "\(output)")
            #expect(!output.contains("public struct Depot"), "\(output)")
            #expect(!output.contains("extension Crate"), "\(output)")
        }
    }

    /// The base subscript's default is its one implementation, once however many conformers take it, and is the restating protocol's implementation too, where nothing at all was listed but a conformer's header.
    @Test
    func aDefaultSubscriptIsListedOnTheBaseAndTheRestatement() async throws {
        try await Self.fixture().withEngine { engine in
            let base = try await engine.lookup(symbol: "Named.subscript", freshness: engine.ensureFresh())
            let restated = try await engine.lookup(symbol: "Refined.subscript", freshness: engine.ensureFresh())

            let listed = "  Sources/GizmoCore/Named.swift (1):\n    :18  subscript(_:)  | public subscript(index: Int) -> String {"
            #expect(base.contains("implementations of GizmoCore.Named.subscript(_:) (1):\n" + listed), "\(base)")
            #expect(restated.contains("implementations of GizmoCore.Refined.subscript(_:) (1):\n" + listed), "\(restated)")
            for output in [base, restated] {
                #expect(!output.contains("public struct Depot"), "\(output)")
                #expect(!output.contains("extension Crate"), "\(output)")
            }
        }
    }

    /// A witness whose definition the store holds only outside the tree — the SDK's interface, a dependency the index never covers — stays listed at the extension that makes it one; only the struct's own property is listed where it is written.
    @Test
    func aWitnessDefinedOutsideTheTreeKeepsItsConformanceSite() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Counted.count", freshness: engine.ensureFresh())

            #expect(output.contains("implementations of GizmoCore.Counted.count (3):\n  Sources/GizmoCore/Counted.swift (3):\n    :7  count  | extension Array: Counted {}\n    :9  count  | extension Tally: Counted {}\n    :12  count  | public var count: Int {"), "\(output)")
            #expect(!output.contains("swiftinterface"), "\(output)")
            #expect(!output.contains(".vendor"), "\(output)")
            #expect(!output.contains(":0 "), "\(output)")
        }
    }
}
