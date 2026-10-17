//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The lines a semantic `where` lists by written name for a function are the calls whose whole argument list can be the declaration's, the labels after the first, the count and the defaults included, and never another member's declaration of the same name.
@Suite(.temporaryDirectories, .serialized)
struct WhereByNameLaterLabelsTests {
    private static var unbuilt: String {
        "not in the build, mention the name: "
    }

    /// A committed package built with its tests and an index store, beside a stray test file outside any target that writes calls of three functions with the argument lists they can and cannot take, and a declaration of another `make`.
    private static func makeBuiltRepo(writingDeclarationAndString: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        #expect(try TemporaryDirectory.entries(containing: root.lastPathComponent) == [root.lastPathComponent], sourceLocation: sourceLocation)
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public enum Seeds {
                public static func of(_ diffs: [Int], store: Int) -> Int {
                    store
                }

                public static func make(_ a: Int, b: Int = 0) -> Int {
                    a + b
                }

                public static func run(_ n: Int, body: () -> Void) {
                    body()
                }
            }

            """,
            to: "Sources/Lib/Seeds.swift",
            in: root
        )
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Seeds.make(1) == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            """
            @testable import Lib
            import Testing

            enum Other {
                static func make(_ a: Int) -> Int { a }
            }

            @Test func strays() {
                let d = [1], s = 2, failures = [3], x = 4
                _ = Seeds.of([1], store: s)
                _ = Seeds.of(failures, changedFiles: x)
                _ = Seeds.of([])
                _ = Seeds.of(
                    d,
                    store: s
                )
                _ = Seeds.make(1)
                _ = Seeds.make(1, b: 2)
                _ = Seeds.make(1, c: 2)
                Seeds.run(1) { }
            }

            """,
            to: "Fixtures/GizmoTests.swift",
            in: root
        )
        if writingDeclarationAndString {
            try TestSources.write(
                """
                import Testing

                enum Sprocket: Sendable {
                    static func of(_ diffs: [Int], store: Int) -> Int { store }
                }

                func note() -> String {
                    "Seeds.of"
                }

                """,
                to: "Fixtures/WidgetTests.swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        return root
    }

    /// Only the calls whose arguments fit the declaration keep their line: the later label must match, a one-argument call of a two-parameter function is out, a defaulted parameter may be left out or given, an unknown label is refused, a trailing closure fills the closure parameter, a call written across lines counts, and another member's `func make` is not a use.
    @Test
    func theUnbuiltLinesAreTheCallsWhoseWholeArgumentListFits() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let expected = [
            "Seeds.of": "Fixtures/GizmoTests.swift:10,13",
            "Seeds.make": "Fixtures/GizmoTests.swift:17,18",
            "Seeds.run": "Fixtures/GizmoTests.swift:20",
        ]
        for (symbol, listing) in expected.sorted(by: { $0.key < $1.key }) {
            let answer = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
            let rows = answer.split(separator: "\n").map(String.init)
            #expect(rows.contains(Self.unbuilt + listing), "\(symbol): \(answer)")
            #expect(rows.count { $0.hasPrefix(Self.unbuilt) } == 1, "\(symbol): \(answer)")
        }
    }

    /// The callers answer counts calls: a same-named `static func of` declaration and the string literal `"Seeds.of"` are no call and are left out, and a call whose arguments do not fit stays out.
    @Test
    func theCallersAnswerDropsADeclarationAndAStringLiteral() async throws {
        let root = try await Self.makeBuiltRepo(writingDeclarationAndString: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let answer = try await engine.lookup(symbol: "Seeds.of", freshness: engine.ensureFresh())
        let row = answer.split(separator: "\n").map(String.init).first { $0.hasPrefix(Self.unbuilt) } ?? ""

        #expect(row == Self.unbuilt + "Fixtures/GizmoTests.swift:10,13", "\(answer)")
    }

    /// A rename sweep keeps both: the declaration line implementing the requirement and the string literal naming it are listed under `--refs`, and a call of a different label list still is not.
    @Test
    func theRefsSweepKeepsTheDeclarationAndTheStringLiteral() async throws {
        let root = try await Self.makeBuiltRepo(writingDeclarationAndString: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let answer = try await engine.lookup(symbol: "Seeds.of", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
        let row = answer.split(separator: "\n").map(String.init).first { $0.hasPrefix(Self.unbuilt) } ?? ""

        #expect(row.contains("Fixtures/WidgetTests.swift:4,8"), "\(answer)")
        #expect(row.contains("Fixtures/GizmoTests.swift:10,13"), "\(answer)")
        #expect(!row.contains("11"), "\(answer)")
    }

    /// A committed package built with its tests, beside a stray test file outside any target that writes calls with labelled trailing closures, a trailing closure on the next line, an unspaced comparison among the arguments, and a closure label no parameter has.
    private static func makeTrailingClosureRepo() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public enum Seeds {
                public static func run(_ n: Int, body: () -> Void, done: () -> Void) {}
                public static func one(_ n: Int, body: () -> Void) {}
                public static func pick(_ a: Bool, by: Int) {}
            }

            """,
            to: "Sources/Lib/Seeds.swift",
            in: root
        )
        try TestSources.write("import Testing\n\n@Test func reads() {}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            """
            @testable import Lib
            import Testing

            @Test func strays() {
                let i = 1, n = 2
                Seeds.run(1) { } done: { }
                Seeds.run(1) {
                } done: {
                }
                Seeds.run(1) { } oops: { }
                Seeds.one(1)
                { }
                Seeds.pick(i<n, by: n>i ? 1 : 2)
            }

            """,
            to: "Fixtures/GizmoTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        return root
    }

    private static func unbuiltRow(for symbol: String, in engine: SiftEngine) async throws -> String {
        let answer = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        return answer.split(separator: "\n").map(String.init).first { $0.hasPrefix(unbuilt) } ?? "no row: \(answer)"
    }

    /// Trailing closures count whether labelled, spread over lines, or on the line after the parenthesis, and a label no parameter has refuses the call.
    @Test
    func theTrailingClosuresAreReadWithTheirLabelsAcrossLines() async throws {
        let root = try await Self.makeTrailingClosureRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        #expect(try await Self.unbuiltRow(for: "Seeds.run", in: engine) == Self.unbuilt + "Fixtures/GizmoTests.swift:6,7")
        #expect(try await Self.unbuiltRow(for: "Seeds.one", in: engine) == Self.unbuilt + "Fixtures/GizmoTests.swift:11")
    }

    /// A `<` and a `>` among the arguments that compare are no generic clause: the call keeps both arguments and is listed.
    @Test
    func anUnspacedComparisonAmongTheArgumentsIsNoGenericClause() async throws {
        let root = try await Self.makeTrailingClosureRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        #expect(try await Self.unbuiltRow(for: "Seeds.pick", in: engine) == Self.unbuilt + "Fixtures/GizmoTests.swift:13")
    }
}
