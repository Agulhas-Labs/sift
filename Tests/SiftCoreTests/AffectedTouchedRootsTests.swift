//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` with a store built over the change: the resolved walk is rooted at the declarations the diff touched in each changed file and what in the same file reaches them, never at every declaration in the file.
@Suite(.serialized, .temporaryDirectories)
struct AffectedTouchedRootsTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    private static var gizmo: String {
        """
        public struct Gizmo {
            public init() {}
            public func spin() -> Int { 1 }
            public func idle() -> Int { 0 }
            public func tune(_ value: Int) -> Int { value }
            public func tune(_ value: Double) -> Int { Int(value) }
        }
        """
    }

    private static var sprocket: String {
        """
        public enum Sprocket {
            static func polish() -> Int { 3 }
            public static func shine() -> Int { polish() }
        }
        """
    }

    private static var suites: String {
        """
        import Testing
        @testable import Lib

        struct GizmoTests {
            @Test func spins() { #expect(Gizmo().spin() == 2) }
        }

        struct BystanderTests {
            @Test func idles() { #expect(Gizmo().idle() == 0) }
        }

        struct IndirectTests {
            @Test func shines() { #expect(Sprocket.shine() == 4) }
        }

        struct AlphaTests {
            @Test func tunes() { #expect(Gizmo().tune(5) == 5) }
        }
        """
    }

    /// The `affected` answer at one hop for an uncommitted edit built over: one member of `Gizmo` changed and its `Int` overload of `tune` removed, and `Sprocket`'s private helper changed under the member that calls it.
    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write(gizmo, to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write(sprocket, to: "Sources/Lib/Sprocket.swift", in: root)
        try TestSources.write(suites, to: "Tests/LibTests/LibTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let edited = gizmo
            .replacingOccurrences(of: "func spin() -> Int { 1 }", with: "func spin() -> Int { 2 }")
            .replacingOccurrences(of: "    public func tune(_ value: Int) -> Int { value }\n", with: "")
        try TestSources.write(edited, to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write(sprocket.replacingOccurrences(of: "{ 3 }", with: "{ 4 }"), to: "Sources/Lib/Sprocket.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(depth: 1), freshness: freshness)
    }

    /// One fixture for the four rules, since each needs a build.
    @Test
    func theWalkStartsFromTheTouchedDeclarationsAndWhatInTheirFileReachesThem() async throws {
        let output = try await Self.answer()

        // The touched member's test is reached; a test calling only an untouched member of the same file is not.
        #expect(output.contains("LibTests.GizmoTests/spins() — 1 hop"))
        #expect(!output.contains("BystanderTests"))
        // The member calling the touched helper in its own file is a root, so its test is one hop out, inside the bound.
        #expect(output.contains("LibTests.IndirectTests/shines() — 1 hop"))
        // Each file's line says how many of its declarations the diff touched.
        #expect(output.contains("  Sources/Lib/Gizmo.swift — added or modified, 1 of 5 declarations touched"))
        #expect(output.contains("  Sources/Lib/Sprocket.swift — added or modified, 1 of 3 declarations touched"))
        // The removed overload is seeded by its old name, so the call now resolving to the other overload is reached by its call site.
        #expect(output.contains("LibTests.AlphaTests/tunes() — 1 hop, name match"))
        #expect(output.contains("resolved walk — the declarations the diff removed or renamed were seeded by their old names (tune)"))
    }

    /// The sources of the dispatch fixture, before its edit: a witness, an override and a decoding initializer each reached only through what declares or implements it, an overloaded free function, a type whose stored property seeds it, another file's same-named nested type, two witnesses of library requirements that a non-test declaration also references, and a member with no bases that only a non-test declaration references.
    private static var dispatchSources: [String: String] {
        [
            "Sources/Lib/Shape.swift": "public protocol Shape {\n    func area() -> Int\n}\n",
            "Sources/Lib/Square.swift": "public struct Square: Shape {\n    public init() {}\n    public func area() -> Int { 4 }\n}\n",
            "Sources/Lib/Base.swift": "open class Base {\n    public init() {}\n    open func run() -> Int { 1 }\n}\n",
            "Sources/Lib/Child.swift": "public final class Child: Base {\n    override public func run() -> Int { 2 }\n}\n",
            "Sources/Lib/Factory.swift": "public func square() -> any Shape { Square() }\npublic func child() -> Base { Child() }\n",
            "Sources/Lib/Point.swift": """
            public struct Point: Decodable {
                public let x: Int
                public init(from decoder: Decoder) throws {
                    x = try decoder.singleValueContainer().decode(Int.self)
                }
            }

            """,
            "Sources/Lib/Tune.swift": "public func tune(_ value: Int) -> String { \"int\" }\npublic func tune(_ value: Any) -> String { \"any\" }\n",
            "Sources/Lib/Widget.swift": "public struct Widget {\n    public var size = 1\n    public init() {}\n}\n",
            "Sources/Lib/Holder.swift": "// A holder.\npublic enum Holder {\n    public struct Widget {\n        public init() {}\n    }\n}\n",
            "Sources/Lib/Cog.swift": "struct Cog: Identifiable {\n    var name: String\n    var id: String { name.lowercased() }\n}\n",
            "Sources/Lib/Keys.swift": "func keys<T: Identifiable>(_ xs: [T]) -> [T.ID] { xs.map(\\.id) }\n",
            "Sources/Lib/Label.swift": "func label(_ cog: Cog) -> String { \"#\" + cog.id }\n",
            "Sources/Lib/Knob.swift": """
            public struct Knob {
                public let turns: Int
            }

            extension Knob: Decodable {
                public init(from decoder: Decoder) throws {
                    turns = try decoder.singleValueContainer().decode(Int.self)
                }
            }

            """,
            "Sources/Lib/Reload.swift": "func reload(_ decoder: Decoder) throws -> Knob { try Knob(from: decoder) }\n",
            "Sources/Lib/Dial.swift": "public struct Dial {\n    public init() {}\n    public func turn() -> Int { 1 }\n}\n",
            "Sources/Lib/Panel.swift": "func panel() -> Int { Dial().turn() }\n",
            "Tests/LibTests/LibTests.swift": """
            import Foundation
            import Testing
            @testable import Lib

            struct SquareTests {
                @Test func areas() { #expect(square().area() == 5) }
            }

            struct ChildTests {
                @Test func runs() { #expect(child().run() == 3) }
            }

            struct PointTests {
                @Test func decodes() throws { #expect(try JSONDecoder().decode(Point.self, from: Data("3".utf8)).x == 4) }
            }

            struct TuneTests {
                @Test func tunes() { #expect(tune(5) == "int") }
            }

            struct WidgetTests {
                @Test func sizes() { #expect(Widget().size == 2) }
            }

            struct HolderTests {
                @Test func holds() { _ = Holder.Widget() }
            }

            struct KeysTests {
                @Test func keys() { #expect(Lib.keys([Cog(name: "A")]) == ["a"]) }
            }

            struct KnobTests {
                @Test func decodes() throws { #expect(try JSONDecoder().decode(Knob.self, from: Data("3".utf8)).turns == 4) }
            }

            struct DialTests {
                @Test func builds() { _ = Dial() }
            }

            """,
        ]
    }

    /// The edit built over: one body each in `Square.area`, `Child.run`, `Point.init(from:)`, `Cog.id`, `Knob.init(from:)` and `Dial.turn`, the `Int` overload of `tune` taking a `String`, `Widget`'s stored default, and only a comment in `Holder.swift`.
    private static var dispatchEdits: [String: (String, String)] {
        [
            "Sources/Lib/Square.swift": ("{ 4 }", "{ 5 }"),
            "Sources/Lib/Child.swift": ("{ 2 }", "{ 3 }"),
            "Sources/Lib/Point.swift": ("decode(Int.self)", "decode(Int.self) + 1"),
            "Sources/Lib/Tune.swift": ("_ value: Int", "_ value: String"),
            "Sources/Lib/Widget.swift": ("size = 1", "size = 2"),
            "Sources/Lib/Holder.swift": ("// A holder.", "// A holder of widgets."),
            "Sources/Lib/Cog.swift": ("name.lowercased()", "name.lowercased() + \"\""),
            "Sources/Lib/Knob.swift": ("decode(Int.self)", "decode(Int.self) + 1"),
            "Sources/Lib/Dial.swift": ("{ 1 }", "{ 2 }"),
        ]
    }

    /// The dispatch fixture, committed, edited and built once for the tests that read it.
    private static func dispatchFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "affected-touched-dispatch") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            for (path, source) in dispatchSources {
                try TestSources.write(source, to: path, in: root)
            }
            try TestSources.commitAll(in: root, message: "dispatch fixture")
            for (path, source) in dispatchSources {
                if let edit = dispatchEdits[path] {
                    try TestSources.write(source.replacingOccurrences(of: edit.0, with: edit.1), to: path, in: root)
                }
            }
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
    }

    /// The `affected` answer at one hop over the dispatch fixture.
    private static func dispatchAnswer() async throws -> String {
        try await dispatchFixture().withEngine { engine in
            try await engine.affected(options: AffectedOptions(depth: 1), freshness: engine.ensureFresh())
        }
    }

    /// A witness called through its protocol is reached from the requirement it implements, at one hop, though the test names neither it nor its type.
    @Test
    func aWitnessCalledThroughItsProtocolIsReachedFromTheRequirement() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.SquareTests/areas() — 1 hop"), "\(output)")
    }

    /// An override called through its base class is reached from the base member it overrides, at one hop.
    @Test
    func anOverrideCalledThroughItsBaseIsReachedFromTheBaseMember() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.ChildTests/runs() — 1 hop"), "\(output)")
    }

    /// A decoding initializer nothing references, called by the decoder, roots its type, so a test decoding the type is reached.
    @Test
    func aMemberNothingReferencesFallsBackToItsType() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.PointTests/decodes() — 1 hop"), "\(output)")
    }

    /// An overload whose signature changed is seeded by its name, so the unedited call now binding to the other overload is reached by its call site.
    @Test
    func aCallableWhoseSignatureChangedIsSeededByItsName() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.TuneTests/tunes() — 1 hop, name match"), "\(output)")
        #expect(output.contains("resolved walk — the declarations the diff changed the signature of were seeded by their old names (tune)"), "\(output)")
    }

    /// A type seeded by one file's change roots that file's type only, never a same-named type another changed file declares.
    @Test
    func aTypeSeedRootsOnlyItsOwnFilesType() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.WidgetTests/sizes() — 1 hop"), "\(output)")
        #expect(!output.contains("HolderTests"), "\(output)")
    }

    /// A witness of a library requirement roots its type though a declaration of its own module references it, so a test reaching it through a generic over that requirement is listed.
    @Test
    func aWitnessOfALibraryRequirementRootsItsTypeThoughSomethingElseReferencesIt() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.KeysTests/keys() — 1 hop"), "\(output)")
    }

    /// A decoding initializer written in an extension and called by a function of its module roots its type, so a test decoding the type is listed.
    @Test
    func aDecodingInitializerCalledElsewhereRootsItsType() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(output.contains("LibTests.KnobTests/decodes() — 1 hop"), "\(output)")
    }

    /// A member that implements nothing and that a declaration other than a test references does not root its type, so a test touching only the type is not listed.
    @Test
    func aMemberWithNoBasesThatSomethingReferencesDoesNotRootItsType() async throws {
        let output = try await Self.dispatchAnswer()

        #expect(!output.contains("DialTests"), "\(output)")
    }
}
