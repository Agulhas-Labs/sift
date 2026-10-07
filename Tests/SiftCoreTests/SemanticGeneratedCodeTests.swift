//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Code the compiler or a macro generates around what is written — a property wrapper's `$` and `_` siblings, a `#Preview`'s expansion, an observer `@Observable` moves — and how `where` lists the uses the store records through it, pinned on a real build.
@Suite(.temporaryDirectories, .serialized)
struct SemanticGeneratedCodeTests {
    /// What a use inside an observer a macro moved cannot show, as the answer words it — spelled out so a change to the wording is a change a test sees.
    static var movedObserverBoundary: String {
        "observers: a macro that moves a property into generated storage, as @Observable does, moves its didSet and willSet with it — the store records their uses at the macro's line, never where they are written, so a reference sweep lists none of their lines"
    }

    /// A SwiftUI view whose `@State` properties are used only through their wrapper's siblings, a `#Preview` that builds it, and an `@Observable` class whose property has a `didSet`.
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
            public final class Lamp {
                public var watched = 0 {
                    didSet {
                        if watched > 10 { watched = 10 }
                    }
                }
                public init() {}
            }
            """,
            to: "Sources/GizmoCore/Lamp.swift",
            in: root
        )
        try TestSources.write(
            """
            import GizmoCore
            import SwiftUI

            struct Panel: View {
                @State private var flag = false
                @State private var count = 0
                let lamp: Lamp

                init(lamp: Lamp) {
                    self.lamp = lamp
                    _count = State(initialValue: 3)
                }

                var body: some View {
                    VStack {
                        Toggle("f", isOn: $flag)
                        Text("\\(count)")
                    }
                }
            }

            #Preview {
                Panel(lamp: Lamp())
            }
            """,
            to: "Sources/GizmoApp/Panel.swift",
            in: root
        )
        try TestSources.write(idle(flag: "@State var flag = false"), to: "Sources/GizmoApp/Idle.swift", in: root)
        try TestSources.write(
            """
            struct Hand {
                var flag = false
                var _flag = 0
                func peek() -> Int { _flag }
                func look() -> Bool { flag }
            }
            """,
            to: "Sources/GizmoCore/Hand.swift",
            in: root
        )
        try TestSources.write(
            """
            @propertyWrapper
            struct Clamp {
                var wrappedValue: Int
                init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            }

            struct Meter {
                @Clamp var amount = 3
                mutating func reset() {
                    _amount = Clamp(wrappedValue: 0)
                }
                func show() -> Int { amount }
            }
            """,
            to: "Sources/GizmoCore/Meter.swift",
            in: root
        )
    }

    /// Two views whose `@State` is internal, as a view's often is: `on`, which nothing uses, and `flag`, handed to a `Toggle` — its declaration spelled as given, so a diff can change it.
    static func idle(flag declaration: String) -> String {
        """
        import SwiftUI

        struct Idle: View {
            @State var on = false
            var body: some View { Text("idle") }
        }

        struct Outer: View {
            \(declaration)
            var body: some View {
                Toggle("f", isOn: $flag)
            }
        }
        """
    }

    /// Runs `body` with the engine over the package every read-only test here shares, built once for the suite, and the freshness it reports.
    static func withBuiltEngine(_ body: (SiftEngine, Freshness) async throws -> Void) async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-generated") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
        try await fixture.withEngine { engine in
            try await body(engine, engine.ensureFresh())
        }
    }

    /// `@State`'s `$flag` is a declaration of its own, and the store records `Toggle(isOn: $flag)` on it and nothing on `flag` — so a property used only through a binding, SwiftUI's commonest shape, answered "no reads or writes", which reads as dead code.
    ///
    /// Its uses through `$flag` and `_count` are listed, marked with the sibling they went through, and a reference sweep lists them as lines to rename.
    ///
    /// And only those: the siblings' own accessors are the compiler's. An internal `@State var on` gets a `$on` whose getter reads `_on`, recorded as an implicit read at the declaration — so a property nothing uses read as used through its own storage, its sweep named `_on`, a spelling written nowhere, and a used one carried that row beside its real ones.
    @Test
    func aWrappedPropertyListsItsUsesThroughItsProjectionAndItsStorage() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let flag = try await engine.lookup(symbol: "Panel.flag", freshness: freshness)
            let count = try await engine.lookup(symbol: "Panel.count", freshness: freshness)
            let sweep = try await engine.lookup(symbol: "Panel.flag", freshness: freshness, options: WhereOptions(includeReferences: true))
            let unused = try await engine.lookup(symbol: "Idle.on", freshness: freshness)
            let unusedSweep = try await engine.lookup(symbol: "Idle.on", freshness: freshness, options: WhereOptions(includeReferences: true))
            let internalFlag = try await engine.lookup(symbol: "Outer.flag", freshness: freshness)

            #expect(flag.contains("reads and writes of GizmoApp.Panel.flag (1):"))
            #expect(flag.contains("    :16  getter:body — read via $flag  | Toggle(\"f\", isOn: $flag)"))
            #expect(!flag.contains("no reads or writes"))
            #expect(count.contains("reads and writes of GizmoApp.Panel.count (2):"))
            #expect(count.contains("    :11  init(lamp:) — write via _count  | _count = State(initialValue: 3)"))
            #expect(count.contains("    :17  getter:body — read  | Text(\"\\(count)\")"))
            #expect(sweep.contains("references to GizmoApp.Panel.flag (1 in 1 file, including $flag):"))
            #expect(sweep.contains("  Sources/GizmoApp/Panel.swift (1):\n    :16  | Toggle(\"f\", isOn: $flag)"))
            #expect(unused.contains("no reads or writes of GizmoApp.Idle.on recorded in the store"))
            #expect(!unused.contains("getter:$on"))
            #expect(unusedSweep.contains("no references to GizmoApp.Idle.on recorded in the store"))
            #expect(!unusedSweep.contains("including _on"))
            #expect(internalFlag.contains("reads and writes of GizmoApp.Outer.flag (1):\n  Sources/GizmoApp/Idle.swift (1):\n    :11  getter:body — read via $flag  | Toggle(\"f\", isOn: $flag)\n"))
            #expect(!internalFlag.contains("getter:$flag"))
        }
    }

    /// A `#Preview`'s closure is an argument to a macro at file scope, so the store relates a call written in it to nothing, and records it again, implicit, on the `#Preview` line inside the `makePreview()` the expansion generates — two calls were listed as three, the extra under a generated name and the real one as an unknown caller.
    @Test
    func aPreviewsCopyOfAWrittenCallIsNeverListedAndTheCallIsNamedByThePreview() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let lamp = try await engine.lookup(symbol: "Lamp.init()", freshness: freshness)
            let panel = try await engine.lookup(symbol: "Panel.init(lamp:)", freshness: freshness)
            let sweep = try await engine.lookup(symbol: "Lamp.init()", freshness: freshness, options: WhereOptions(includeReferences: true))

            for output in [lamp, panel] {
                #expect(output.contains("(1):\n  Sources/GizmoApp/Panel.swift (1):\n    :23  (inside #Preview)  | Panel(lamp: Lamp())"))
                #expect(!output.contains("makePreview()"))
                #expect(!WhereStoreSiteTextTests.located(output).contains("Panel.swift:22"))
                #expect(!output.contains("(unknown caller)"))
            }

            #expect(sweep.contains("(1 in 1 file):\n  Sources/GizmoApp/Panel.swift (1):\n    :23  | Panel(lamp: Lamp())"))
        }
    }

    /// `@Observable` moves a property's `didSet` onto the storage it generates, and the store records every use inside it at the `@Observable` attribute — the line it is written on has no occurrence at all — so its row says it was moved rather than naming the generated `didSet:_watched` as if the attribute line were where it is written, the gap is said beside it, and a reference sweep lists no line with nothing on it to rename.
    @Test
    func anObserverAMacroMovedSaysSoAndItsGapIsDeclared() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let watched = try await engine.lookup(symbol: "Lamp.watched", freshness: freshness)
            let sweep = try await engine.lookup(symbol: "Lamp.watched", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(watched.contains("reads and writes of GizmoCore.Lamp.watched (1):"))
            #expect(watched.contains("    :3  didSet of watched (moved by a macro) — read and write  | @Observable"))
            #expect(watched.contains(SemanticUnitTests.propertyBoundary + "\n" + Self.movedObserverBoundary))
            #expect(!watched.contains("didSet:_watched"))
            #expect(sweep.contains("no references to GizmoCore.Lamp.watched recorded in the store"))
            #expect(!sweep.contains("Lamp.swift (1): 3"))
        }
    }

    /// A `_name` written in code is read for what the store says it is.
    ///
    /// A `_flag` declared beside `flag` is a property of its own, never the storage a wrapper declares, so its uses are never folded into `flag`'s. A wrapper declared in the property's own module declares no `_amount` the store records: `_amount = Clamp(wrappedValue: 0)` is recorded on `amount` itself, as a read — so a write was listed as one — and its row says the spelling it went through and that it is a use, never an access the store did not record.
    @Test
    func aStorageNameWrittenInCodeIsReadForWhatTheStoreSaysItIs() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let flag = try await engine.lookup(symbol: "Hand.flag", freshness: freshness)
            let amount = try await engine.lookup(symbol: "Meter.amount", freshness: freshness)
            let sweep = try await engine.lookup(symbol: "Meter.amount", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(flag.contains("reads and writes of GizmoCore.Hand.flag (1):\n  Sources/GizmoCore/Hand.swift (1):\n    :5  look() — read  | func look() -> Bool { flag }\n"))
            #expect(!flag.contains("peek()"))
            #expect(!flag.contains("via _flag"))
            #expect(amount.contains("reads and writes of GizmoCore.Meter.amount (2):"))
            #expect(amount.contains("    :10  reset() — used via _amount  | _amount = Clamp(wrappedValue: 0)\n"))
            #expect(amount.contains("    :12  show() — read  | func show() -> Int { amount }\n"))
            #expect(!amount.contains("    :10  reset() — read"))
            #expect(sweep.contains("references to GizmoCore.Meter.amount (2 in 1 file, including _amount):"))
        }
    }

    /// `sift diff` lists a changed property's uses from the same store query `where` does, and marks a use through a wrapper's sibling the same way — `$flag` handed to a `Toggle` is never listed as `flag` itself.
    @Test
    func aDiffMarksAUseThroughAWrappersSiblingAsWhereDoes() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.idle(flag: "@State var flag: Bool = false"), to: "Sources/GizmoApp/Idle.swift", in: root)
        try TestSources.commitAll(in: root, message: "annotate")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))
        let output = try await engine.diff(options: DiffOptions(range: range, member: nil, offset: 0), freshness: freshness)

        #expect(output.contains("~ Outer.flag — resolved by the index store: 1 use\n      getter:body — Sources/GizmoApp/Idle.swift:11 — via $flag\n"))
    }

    /// The sibling-spelling cache `where` reads a wrapped property's uses through lives for one query only — never on the store across queries.
    ///
    /// A use file edited between two queries on the same engine, with no rebuild, is read as it now stands: the second query sees the new spelling, not the first query's bytes held over from before the edit.
    ///
    /// `$amount` here is spelled through the wrapper's projection, given wider access than the wrapper's own storage, so the use can live in a file of its own, apart from the declaration — the declaration's file is never touched, so nothing here is a `changed since last build` refusal.
    @Test
    func theSiblingSpellingCacheDoesNotOutliveOneQuery() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Depot", targets: [.target(name: "DepotKit")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            @propertyWrapper
            public struct Clamp {
                public var wrappedValue: Int
                public var projectedValue: Int { wrappedValue }
                public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }
            }

            public struct Meter {
                @Clamp public var amount = 3
                public init() {}
            }
            """,
            to: "Sources/DepotKit/Meter.swift",
            in: root
        )
        let useFile = "Sources/DepotKit/Peek.swift"
        try TestSources.write(
            """
            extension Meter {
                func peek() -> Int {
                    $amount
                }
            }
            """,
            to: useFile,
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let firstFreshness = try await engine.ensureFresh()
        let first = try await engine.lookup(symbol: "Meter.amount", freshness: firstFreshness)
        #expect(first.contains("via $amount"))

        // Same column, same line, only the sigil changes — no rebuild needed for the store's own occurrence data to still apply.
        try TestSources.write(
            """
            extension Meter {
                func peek() -> Int {
                    _amount
                }
            }
            """,
            to: useFile,
            in: root
        )

        let secondFreshness = try await engine.ensureFresh()
        let second = try await engine.lookup(symbol: "Meter.amount", freshness: secondFreshness)

        #expect(second.contains("via _amount"))
        #expect(!second.contains("via $amount"))
    }
}
