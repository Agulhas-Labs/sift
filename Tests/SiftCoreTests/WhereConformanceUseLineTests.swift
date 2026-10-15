//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a protocol's conformance line that also uses the protocol keeping its usage row and counting as a use, with the store and without it, while a line holding only a conformance is still folded into the conformers block.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformanceUseLineTests {
    /// A built package whose protocol is conformed to by three types, one of them on a line that also uses the protocol as a property's type, and used once elsewhere.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformance-use-line") { root in
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
            try TestSources.write("public protocol P {}\n", to: "Sources/Lib/P.swift", in: root)
            try TestSources.write(
                """
                public struct A: P { public var p: (any P)? }
                public struct B: P {}
                public struct C: P {}
                """,
                to: "Sources/Lib/Parts.swift",
                in: root
            )
            try TestSources.write("public func use(_ value: any P) {}\n", to: "Sources/Lib/Use.swift", in: root)
            try TestSources.commitAll(in: root, message: "conformance use line fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    private static var aLine: String {
        "public struct A: P { public var p: (any P)? }"
    }

    /// With the store, the line that both conforms and uses is a row and a use; the two pure conformances are counted and not listed.
    @Test
    func storeKeepsTheUseOnAConformanceLine() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.P: 4 references in 2 files, 2 of them the conformances listed below"), "\(output)")
            #expect(output.contains("  Sources/Lib/Parts.swift (1):\n    :1  | \(Self.aLine)\n  Sources/Lib/Use.swift (1):"), "\(output)")
            #expect(!output.contains("| public struct B: P {}"), "\(output)")
            #expect(!output.contains("| public struct C: P {}"), "\(output)")
            #expect(output.contains("  Lib.A — struct — Sources/Lib/Parts.swift:1 — direct"), "\(output)")
        }
    }

    /// With the store under `--refs`, the sweep lists the line that also uses the protocol and folds only the two pure conformances.
    @Test
    func storeSweepKeepsTheUseOnAConformanceLine() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let sweep = try #require(output.components(separatedBy: "references to Lib.P (").last)

            #expect(output.contains("used by Lib.P: 4 references in 2 files, 2 of them the conformances listed below"), "\(output)")
            #expect(sweep.hasPrefix("4 in 2 files, 2 of them the conformances listed below):"), "\(sweep)")
            #expect(sweep.contains("Sources/Lib/Parts.swift (1)"), "\(sweep)")
            #expect(sweep.contains(Self.aLine), "\(sweep)")
            #expect(!sweep.contains("public struct B: P {}"), "\(sweep)")
            #expect(!sweep.contains("public struct C: P {}"), "\(sweep)")
        }
    }

    /// Without the store, the scan by written name keeps the same line as a use and folds the two pure conformances.
    @Test
    func scanByNameKeepsTheUseOnAConformanceLine() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            #expect(output.contains("(4 uses by written name in 2 files, 2 of them the conformances listed below)"), "\(output)")
            #expect(output.contains("  Sources/Lib/Parts.swift (1):\n    :1  | \(Self.aLine)\n  Sources/Lib/Use.swift (1):"), "\(output)")
            #expect(!output.contains("| public struct B: P {}"), "\(output)")
            #expect(!output.contains("| public struct C: P {}"), "\(output)")
        }
    }

    /// Without the store under `--refs`, the sweep lists every line, the one that conforms and uses among them.
    @Test
    func scanByNameSweepListsTheConformanceLine() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "P", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false, includeReferences: true))

            #expect(output.contains(Self.aLine), "\(output)")
            #expect(!output.contains("of them the conformances listed below"), "\(output)")
        }
    }

    /// A built package whose protocol is conformed to on wrapped clauses, a generic head and shared lines, each with or without a use of the protocol on the same line.
    private static func shapesFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformance-use-line-shapes") { root in
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
            try TestSources.write("public protocol Q {}\npublic protocol Z {}\n", to: "Sources/Lib/Q.swift", in: root)
            try TestSources.write(
                """
                public struct Alpha: Z,
                    Q { public var q: (any Q)? }
                public struct Bravo: Z,
                    Q {}
                public struct Generic<T: Q>: Q {}
                public struct Delta: Q {}; public struct Echo: Q {}
                public struct Foxtrot: Q {}; public struct Golf: Q { public var q: (any Q)? }
                """,
                to: "Sources/Lib/Shapes.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "conformance use line shapes fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    private static let shapeRows = [
        "    :2  | Q { public var q: (any Q)? }",
        "    :5  | public struct Generic<T: Q>: Q {}",
        "    :7  | public struct Foxtrot: Q {}; public struct Golf: Q { public var q: (any Q)? }",
    ]

    private static let foldedShapes = [
        "Q {}",
        "public struct Delta: Q {}; public struct Echo: Q {}",
    ]

    /// The wrapped continuation that holds a use, the generic head that is a use and a conformance, and the mixed shared line are rows; the pure wrapped and pure shared lines are folded.
    @Test
    func storeKeepsTheUseOnWrappedGenericAndSharedLines() async throws {
        try await Self.shapesFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Q", freshness: engine.ensureFresh())

            for row in Self.shapeRows {
                #expect(output.contains(row), "\(row)\n\(output)")
            }
            for line in Self.foldedShapes {
                #expect(!output.contains("| \(line)"), "\(line)\n\(output)")
            }
        }
    }

    /// The same shapes without the store.
    @Test
    func scanByNameKeepsTheUseOnWrappedGenericAndSharedLines() async throws {
        try await Self.shapesFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Q", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            for row in Self.shapeRows {
                #expect(output.contains(row), "\(row)\n\(output)")
            }
            for line in Self.foldedShapes {
                #expect(!output.contains("| \(line)"), "\(line)\n\(output)")
            }
        }
    }

    /// A built package whose protocol is conformed to by declarations of unusual starts, each on a line that also uses the protocol.
    private static func startsFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformance-use-line-starts") { root in
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
            try TestSources.write("public protocol Q {}\n", to: "Sources/Lib/Q.swift", in: root)
            try TestSources.write(
                """
                @available(macOS 1, *) public struct Attributed: Q { public var q: (any Q)? }
                public struct Outer { public struct Nested: Q { public var q: (any Q)? } }
                public struct Host {}
                extension Host: Q { public var q: (any Q)? { nil } }
                public enum Choice: Q { case a; public var q: (any Q)? { nil } }
                public final class Box: Q { public var q: (any Q)? }
                """,
                to: "Sources/Lib/Starts.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "conformance use line starts fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The scan by written name over the starts fixture, reading each file through `source`, given the repository root and the file's path.
    private static func scan(reading source: @escaping @Sendable (URL, String) -> String?) async throws -> String {
        let fixture = try await startsFixture()
        let root = fixture.root
        let scanner = CallSiteScanner(repoRoot: root, enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()))
        return try await fixture.withEngine { engine in
            _ = try await engine.ensureFresh()
            var renderer = WhereRenderer(store: engine.store, callSites: { await scanner.callSites(named: $0) })
            renderer.fileSource = { source(root, $0) }
            return try await renderer.render(query: "Q", semantic: .inactive(note: "semantic disabled (--syntactic)"), options: WhereOptions(includeSemantic: false)).body
        }
    }

    private static let startsRows = [1, 2, 4, 5, 6]

    /// A file that is read keeps a line that also uses the protocol as a row, even where no parsed clause starts where the conformer's row does.
    @Test
    func readFileWhoseStartsDoNotMatchKeepsTheUseLines() async throws {
        let output = try await Self.scan { root, path in
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)).map { "\n" + $0 }
        }

        for line in Self.startsRows {
            #expect(output.contains("    :\(line)  | "), "line \(line)\n\(output)")
        }
    }

    /// A file that cannot be read has each conformer's declaration line stand for its conformance, so the lines fold.
    @Test
    func unreadableFileFoldsTheConformerDeclarationLines() async throws {
        let output = try await Self.scan { _, _ in nil }

        for line in Self.startsRows {
            #expect(!output.contains("    :\(line)  | "), "line \(line)\n\(output)")
        }
    }
}
