//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Which of the index store's occurrences stand for a use, and how many build units a listed line was recorded by — the one rule callers, reads and writes, an enum case's uses, references, overrides and conformers are all read by — pinned on a real build.
@Suite(.temporaryDirectories, .serialized)
struct SemanticUnitTests {
    /// What a property's reads and writes cannot show, as the answer words it — spelled out so a change to the wording is a change a test sees.
    static var propertyBoundary: String {
        "reads and writes: written code only — the store records none made by a synthesized conformance (Equatable, Hashable, Codable) or by name at runtime, so a short or empty list is not proof a property is unused"
    }

    /// What an enum case's uses cannot show, as the answer words it.
    static var caseBoundary: String {
        "uses: written code only — the store records none made by a synthesized conformance (CaseIterable, a raw value's init(rawValue:), Codable) or by name at runtime, so a short or empty list is not proof a case is unused"
    }

    /// The core module's declarations, with `theme` declared as given — a second commit that re-spells it is a changed member to `sift diff`.
    static func shapes(theme: String = "public var theme = \"dark\"") -> String {
        """
        public struct Point: Equatable {
            public var x: Int
            public var y: Int
        }

        public struct Prefs: Codable {
            \(theme)
            public init() {}
        }

        public enum Tone: String, CaseIterable {
            case low, high
        }

        public func same() -> Bool { Point(x: 1, y: 2) == Point(x: 1, y: 2) }
        public func tones() -> Int { Tone.allCases.count + (Tone(rawValue: "low") == nil ? 0 : 1) }

        public func ping() -> Int { 1 }
        public func twice() -> Int { ping() + ping() }

        public protocol Gadget {}

        open class Base {
            public init() {}
            open func run() {}
        }

        public struct Vault {
            var stash = 0
            public var total: Int {
                get { stash }
                _modify { yield &stash }
            }
        }
        """
    }

    /// Every shape the rule meets: `@Observable` properties, one used and one not; two calls on one line; a memberwise initializer; conformances the compiler synthesizes; a modify coroutine; one file compiled into two targets, `GizmoTools` holding a link to `GizmoApp`'s; and a test whose `#expect` spans three lines.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                platforms: [.macOS(.v14)],
                targets: [
                    .target(name: "GizmoCore"),
                    .target(name: "GizmoApp", dependencies: ["GizmoCore"]),
                    .target(name: "GizmoTools", dependencies: ["GizmoCore"]),
                    .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            import Observation

            @Observable
            public final class Dial {
                public var level = 0
                public var spare = 0
                public init() {}
                public func bump() { level += 1 }
            }
            """,
            to: "Sources/GizmoCore/Dial.swift",
            in: root
        )
        try TestSources.write(shapes(), to: "Sources/GizmoCore/Shapes.swift", in: root)
        try TestSources.write(
            """
            import GizmoCore

            public func peek(_ dial: Dial) -> Int {
                dial.level + ping()
            }

            public struct Knob: Gadget {}

            public final class Runner: Base {
                override public func run() {}
            }

            public func tone() -> Tone { .high }
            """,
            to: "Sources/GizmoApp/Use.swift",
            in: root
        )
        let tools = root.appendingPathComponent("Sources/GizmoTools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("Use.swift").path, withDestinationPath: "../GizmoApp/Use.swift")
        try TestSources.write(
            """
            import GizmoCore
            import Testing

            @Test func spans() {
                #expect(
                    ping() == 1
                )
            }
            """,
            to: "Tests/GizmoTests/Checks.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing

            struct LampTests {
                @Test func dimLampWorks() {}
                @Test func v1b() {}
            }
            """,
            to: "Tests/GizmoTests/LampTests.swift",
            in: root
        )
    }

    /// Runs `body` with the engine over the package every read-only test here shares, built once for the suite, and the freshness it reports.
    static func withBuiltEngine(_ body: (SiftEngine, Freshness) async throws -> Void) async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-unit") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        try await fixture.withEngine { engine in
            try await body(engine, engine.ensureFresh())
        }
    }

    /// `@Observable` rewrites each property's getter, setter and modify coroutine to read its key path, and the store records those as five implicit reads at the attribute — so a property nothing uses was listed as read three times over, once under no name at all, and "×3 units" from one build.
    @Test
    func anObservablePropertyListsOnlyTheUsesWrittenInCode() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let spare = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Dial.spare", freshness: freshness) }
            let level = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Dial.level", freshness: freshness) }

            #expect(spare.contains("no reads or writes of GizmoCore.Dial.spare recorded in the store"))
            #expect(level.contains("reads and writes of GizmoCore.Dial.level (2):"))
            #expect(level.contains("    :8  bump() — read and write  | public func bump() { level += 1 }"))
            #expect(level.contains("    :4  peek(_:) — read  ×2 units  | dial.level + ping()"))
            for output in [spare, level] {
                #expect(!WhereStoreSiteTextTests.located(output).contains("Sources/GizmoCore/Dial.swift:3"))
                #expect(!output.contains("getter:"))
                #expect(!output.contains("×3"))
            }
        }
    }

    /// A line's units are the build units that recorded it: two calls one build put on one line are one row with no marker, and a line in a file compiled into two targets is recorded by both — `×2 units` — in every relation alike.
    @Test
    func aLineIsCountedInTheBuildUnitsThatRecordedItInEveryRelation() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let callers = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "ping()", freshness: freshness) }
            let reads = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Dial.level", freshness: freshness) }
            let uses = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Tone.high", freshness: freshness) }
            let overrides = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Base.run()", freshness: freshness) }
            let conformers = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Gadget", freshness: freshness) }

            #expect(callers.contains("    :19  twice()  | public func twice() -> Int { ping() + ping() }"))
            #expect(!callers.contains("    :19  twice()  ×"))
            #expect(callers.contains("    :4  peek(_:)  ×2 units  | dial.level + ping()"))
            #expect(reads.contains("    :8  bump() — read and write  | public func bump() { level += 1 }"))
            #expect(!reads.contains("    :8  bump() — read and write  ×"))
            #expect(reads.contains("    :4  peek(_:) — read  ×2 units  | dial.level + ping()"))
            #expect(uses.contains("    :13  tone()  ×2 units  | public func tone() -> Tone { .high }"))
            #expect(overrides.contains("    :10  run()  ×2 units  | override public func run() {}"))
            #expect(conformers.contains("  GizmoApp.Knob — struct — Sources/GizmoApp/Use.swift:7 — direct  ×2 units"))
        }
    }

    /// `#expect` records each call it wraps twice — where it is written, and again, implicit, at the macro — so a call on the line after `#expect(` was listed on both lines, and a rename sweep counted a line with nothing on it to rename.
    @Test
    func aMacrosCopyOfAWrittenUseIsNeverListed() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let callers = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "ping()", freshness: freshness) }
            let references = try await SemanticStoreWarmUp.settled {
                try await engine.lookup(symbol: "ping()", freshness: freshness, options: WhereOptions(includeReferences: true))
            }

            #expect(callers.contains("callers of GizmoCore.ping() (3):"))
            #expect(callers.contains("    :6  spans()  | ping() == 1"))
            #expect(!WhereStoreSiteTextTests.located(callers).contains("Checks.swift:5"))
            #expect(references.contains("  Tests/GizmoTests/Checks.swift (1):\n    :6  | ping() == 1"))
        }
    }

    /// The store names a modify coroutine with an empty string, and a row credited to one is named by what it is and whose — never left blank, which reads as a field the answer forgot to fill, and never by its kind alone, which leaves the reader to work out whose accessor it is.
    @Test
    func anAccessorTheStoreLeavesUnnamedIsNamedByItsKindAndItsProperty() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let output = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Vault.stash", freshness: freshness) }

            #expect(output.contains("    :32  modify accessor of total — read and write  | _modify { yield &stash }"))
            #expect(!output.contains("(unnamed"))
            #expect(!output.contains("\n   — "))
        }
    }

    /// `@Test` calls the function it is attached to from a function it generates, which the store names by its mangling — a `$s` name spelling `spans`, `Test` and a peer macro's marker — so that caller is named by the macro that made it, never by the mangled name.
    ///
    /// Named whole, as the demangler reads it: the mangling spells a word an earlier name already used as a back-reference — in `GizmoTests`, `struct LampTests { @Test func dimLampWorks() }` spells the test `dim`, a letter standing for `Lamp`, then `Works` — so a name read off the mangling by hand called that test `Works`, and `v1b`, whose tail `1b` spells a length of its own, `b`.
    @Test
    func aCallerAMacroGeneratedIsNamedByTheMacro() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let output = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "spans()", freshness: freshness) }
            let substituted = try await SemanticStoreWarmUp.settled {
                try await engine.lookup(symbol: "LampTests.dimLampWorks()", freshness: freshness)
            }
            let tail = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "LampTests.v1b()", freshness: freshness) }

            #expect(output.contains("    :4  (@Test expansion of spans)  | @Test func spans() {"))
            #expect(substituted.contains("callers of GizmoTests.LampTests.dimLampWorks() (1):\n  Tests/GizmoTests/LampTests.swift (1):\n    :4  (@Test expansion of dimLampWorks)  | @Test func dimLampWorks() {}"))
            #expect(tail.contains("callers of GizmoTests.LampTests.v1b() (1):\n  Tests/GizmoTests/LampTests.swift (1):\n    :5  (@Test expansion of v1b)  | @Test func v1b() {}"))
            for answer in [output, substituted, tail] {
                #expect(!answer.contains("$s"))
                #expect(!answer.contains("(a macro expansion)"))
            }
        }
    }

    /// `@Observable`'s generated accessors read a property at the attribute, where a sweep has nothing to rename — so `--refs` drops them as a property's uses do, and a property nothing uses has no references rather than one on the `@Observable` line.
    @Test
    func aReferenceSweepListsNoneOfAnObservablePropertysGeneratedReads() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let spare = try await SemanticStoreWarmUp.settled {
                try await engine.lookup(symbol: "Dial.spare", freshness: freshness, options: WhereOptions(includeReferences: true))
            }
            let level = try await SemanticStoreWarmUp.settled {
                try await engine.lookup(symbol: "Dial.level", freshness: freshness, options: WhereOptions(includeReferences: true))
            }

            #expect(spare.contains("no references to GizmoCore.Dial.spare recorded in the store"))
            #expect(!spare.contains("Dial.swift (1): 3"))
            #expect(level.contains("  Sources/GizmoCore/Dial.swift (1):\n    :8  | public func bump() { level += 1 }"))
        }
    }

    /// A memberwise initializer's argument is recorded as a plain reference at its label, neither read nor written — so it is listed, marked `referenced`, where a struct only ever built that way read as having a property nothing used.
    @Test
    func aMemberwiseArgumentIsListedAsAReference() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let output = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Point.x", freshness: freshness) }

            #expect(output.contains("reads and writes of GizmoCore.Point.x (1):"))
            #expect(output.contains("    :15  same() — referenced  | public func same() -> Bool { Point(x: 1, y: 2) == Point(x: 1, y: 2) }"))
            #expect(output.contains(Self.propertyBoundary))
        }
    }

    /// What only synthesized code uses has no occurrence at all — a property only a `Codable` conformance reads, a case only `CaseIterable` and `init(rawValue:)` reach — so the empty case says what the store cannot see, directly under it, rather than reading as dead code.
    @Test
    func whatOnlySynthesizedCodeUsesSaysTheStoreCannotSeeIt() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let theme = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Prefs.theme", freshness: freshness) }
            let low = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "Tone.low", freshness: freshness) }

            #expect(theme.contains("no reads or writes of GizmoCore.Prefs.theme recorded in the store\n" + Self.propertyBoundary))
            #expect(low.contains("no uses of GizmoCore.Tone.low recorded in the store\n" + Self.caseBoundary))
        }
    }

    /// `sift diff` states the same gap beside a changed property's store-resolved uses: "0 uses" of a field a synthesized conformance reads is not proof it can go.
    @Test
    func aDiffSaysWhatTheStoreCannotSeeBesideAResolvedPropertysUses() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.shapes(theme: "public var theme: String = \"dark\""), to: "Sources/GizmoCore/Shapes.swift", in: root)
        try TestSources.commitAll(in: root, message: "annotate")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        // `diff` states what the store resolved in its body, not in the header, so a warming open shows up here as a
        // count that is simply wrong rather than as a refusal — all the more reason to wait for the store first.
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))
        let output = try await engine.diff(options: DiffOptions(range: range, member: nil, offset: 0), freshness: freshness)

        #expect(output.contains("~ Prefs.theme — resolved by the index store: 0 uses"))
        #expect(output.contains("  a use the index store resolves is one written in code: a synthesized conformance's"))
    }
}
