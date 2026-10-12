//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The lines a semantic `where` lists by written name for a function or an initializer are the ones written in its call's shape, its name and the label of an opening argument, so a property, a local or a parameter spelling the same word is not listed; a property keeps its bare-name match.
@Suite(.temporaryDirectories, .serialized)
struct WhereByNameLabelsTests {
    private static var unbuilt: String {
        "not in the build, mention the name: "
    }

    private static var notInStore: String {
        "new since last build, not in the store, mention the name: "
    }

    /// A committed package built with its tests and an index store, beside a stray test file outside any target that writes each function's name in a call and as a local, a property or a word, and, given `probes`, a second one writing each in the shapes a call or a reference can take.
    private static func makeBuiltRepo(probes: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
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
            public enum Binary {
                public static func path(invokedAs name: String) -> String {
                    name
                }

                public static func run(_ value: Int) -> Int {
                    value
                }

                public static func reset() -> Int {
                    0
                }

                public static func perform(work: () -> Void) {
                    work()
                }

                public static func aliased(work: Work) {
                    work()
                }

                public static func keyword(in value: Int) -> Int {
                    value
                }

                public static func `default`(value: Int) -> Int {
                    value
                }
            }

            public typealias Work = () -> Void

            public struct Holder {
                public var path = ""
                public init() {}
            }

            public struct Box {
                public let label: Int

                public init(label: Int) {
                    self.label = label
                }
            }

            """,
            to: "Sources/Lib/Binary.swift",
            in: root
        )
        try TestSources.write("public func call(holder: Holder) -> String {\n    Binary.path(invokedAs: holder.path)\n}\n", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.write("public func other() -> Int {\n    2\n}\n", to: "Sources/Lib/Other.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Binary.reset() == 0)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            """
            @testable import Lib
            import Testing

            @Test func strays() {
                let path = Holder().path
                #expect(path == "")
                #expect(Binary.path(invokedAs: path) == path)
                let long = Binary.path(
                    invokedAs: "b"
                )
                let reference = Binary.path(invokedAs:)
                #expect(reference("c") == long)
                #expect(Binary.run(1) == 1)
                let run = 2
                #expect(run == Binary.reset())
                let reset = 3
                Binary.perform {}
                #expect(reset == 3)
            }

            """,
            to: "Fixtures/BetaTests.swift",
            in: root
        )
        if probes {
            try TestSources.write(
                """
                @testable import Lib
                import Testing

                @Test func probes() {
                    let path = 1
                    #expect(path == 1)
                    #expect("\\(Binary.path(invokedAs: "s"))" == "s")
                    let unapplied = Binary.path
                    #expect([1].map(Binary.run) == [1])
                    let commented = Binary.path(
                        // why
                        invokedAs: "c"
                    )
                    let inline = Binary.path( /* c */ invokedAs: "d")
                    Binary.aliased { }
                    Binary.perform() { }
                    #expect(Binary.keyword(in: 1) == 1)
                    #expect(Binary.`default`(value: 2) == 2)
                    let implicit: Box = .in\("it")(label: 1)
                    let explicit = Box.init(label: 2)
                    let called = Box(label: 3)
                    #expect(implicit.label + explicit.label + called.label + inline.count + commented.count + unapplied("u").count == 9)
                    let property = holder.path
                    let own = Self.path
                }

                """,
                to: "Fixtures/GizmoTests.swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        return root
    }

    /// The stray test file's lines are listed for each function only where they call it or reach it as a member, a multi-line call and a reference with labels included, an unlabelled and an empty argument list matching the open parenthesis and a closure parameter its trailing closure, never a local spelling the same word, while the property spelling it keeps every line writing it.
    @Test
    func theUnbuiltLinesAreTheCallsOfAFunctionAndEveryMentionOfAProperty() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let expected = [
            "Binary.path": "Fixtures/BetaTests.swift:7,8,11",
            "Holder.path": "Fixtures/BetaTests.swift:5,6,7,8,11",
            "Binary.run": "Fixtures/BetaTests.swift:13",
            "Binary.reset": "Fixtures/BetaTests.swift:15",
            "Binary.perform": "Fixtures/BetaTests.swift:17",
        ]
        for (symbol, listing) in expected.sorted(by: { $0.key < $1.key }) {
            let answer = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
            let rows = answer.split(separator: "\n").map(String.init)
            #expect(rows.contains(Self.unbuilt + listing), "\(symbol): \(answer)")
            #expect(rows.count { $0.hasPrefix(Self.unbuilt) } == 1, "\(symbol): \(answer)")
        }
    }

    /// Files written since the build list only their calls of the function and the members reached by its name: a new file's call, a stored file's new call under the cited file's mark and one on a line of its own, never the local spelling the same word beside them, which the property's own answer still lists, nor a member access the build recorded where it still stands.
    @Test
    func theChangedFileLinesAreTheCallsOfAFunctionAndEveryMentionOfAProperty() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public func depot(holder: Holder) -> String {\n    let path = holder.path\n    return Binary.path(invokedAs: path)\n}\n", to: "Sources/Lib/Depot.swift", in: root)
        try TestSources.write(
            "public func call(holder: Holder) -> String {\n    Binary.path(invokedAs: holder.path)\n}\n\npublic func again(holder: Holder) -> String {\n    _ = holder.path\n    return Binary.path(\n        invokedAs: holder.path)\n}\n",
            to: "Sources/Lib/Caller.swift",
            in: root
        )
        try TestSources.write("public func other(holder: Holder) -> Int {\n    _ = holder.path.count\n    _ = Holder().path\n    return Binary.path(invokedAs: \"o\").count\n}\n", to: "Sources/Lib/Other.swift", in: root)

        let function = try await engine.lookup(symbol: "Binary.path", freshness: engine.ensureFresh())
        let rows = function.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let property = try await engine.lookup(symbol: "Holder.path", freshness: engine.ensureFresh())

        #expect(rows.contains(Self.notInStore + "Sources/Lib/Depot.swift:3"), "\(function)")
        let mark = try #require(rows.firstIndex { $0.contains("Sources/Lib/Caller.swift") && $0.contains("(file changed since last build)") }, "\(function)")
        #expect(rows.dropFirst(mark + 1).prefix(3).contains("    written since the build, by name: :7"), "\(function)")
        #expect(rows.contains("changed since last build, written since the build, by name: Sources/Lib/Other.swift:4"), "\(function)")
        #expect(property.split(separator: "\n").contains { $0 == Self.notInStore + "Sources/Lib/Depot.swift:2,3" }, "\(property)")
    }

    /// Every shape a call or a reference can take keeps its line: a call in an interpolation, an unapplied reference through its type, comments inside the parenthesis, a trailing closure for a typealiased closure and after `()`, a keyword label and a backticked name, and an initializer through `.init`, `Type.init` and its type name, and `Self.path`; the local spelling the word and a lowercase value's property of it, `holder.path`, are left out.
    @Test
    func everyShapeOfACallOrAReferenceIsListed() async throws {
        let root = try await Self.makeBuiltRepo(probes: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let expected = [
            "Binary.path": "7,8,10,14,24",
            "Binary.run": "9",
            "Binary.aliased": "15",
            "Binary.perform": "16",
            "Binary.keyword": "17",
            "Binary.default": "18",
            "Box.init": "19,20,21",
        ]
        for (symbol, lines) in expected.sorted(by: { $0.key < $1.key }) {
            let answer = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
            let row = try #require(answer.split(separator: "\n").map(String.init).first { $0.hasPrefix(Self.unbuilt) }, "\(symbol): \(answer)")
            #expect(row.contains("Fixtures/GizmoTests.swift:\(lines)") && !row.contains("Fixtures/GizmoTests.swift:\(lines),"), "\(symbol): \(row)")
        }
    }
}
