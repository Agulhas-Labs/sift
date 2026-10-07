//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A property is read and written, never called — so `where` answers for one with its reads and writes from the index store, and an empty answer names what it looked for instead of saying "no callers", which reads as dead code.
@Suite(.temporaryDirectories, .serialized)
struct SemanticPropertyUseTests {
    /// The declaring file, with `gap`'s declaration as given — the one line a range can change without moving any other.
    static func limits(gap: String = "package static let gap = 7") -> String {
        """
        public enum Limits {
            public static let ceiling = 3
            public static var margin: Int { ceiling * 2 }
            \(gap)
            nonisolated(unsafe) public static var budget = 1
            public static let unused = 0
        }

        public struct Tally {
            public var count = 0
            public init() {}

            public subscript(slot slot: Int) -> Int {
                get { count + slot }
                set(value) { count = value - slot }
            }
        }

        public struct Shelf {
            public var items = [0, 0, 0]
            public init() {}

            public subscript(slot: Int) -> Int {
                get { items[slot] }
                set(value) { items[slot] = value }
            }
        }
        """
    }

    /// Two modules of one package: every shape of property the complaint met — a stored `static let`, a computed `static var`, a `package static let` read from the other module — plus an instance property and a subscript, written as well as read.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                targets: [
                    .target(name: "GizmoCore"),
                    .target(name: "GizmoApp", dependencies: ["GizmoCore"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(limits(), to: "Sources/GizmoCore/Limits.swift", in: root)
        try TestSources.write(
            """
            func measure() -> Int {
                var tally = Tally()
                tally.count = 5
                tally.count += 1
                Limits.budget = 2
                tally[slot: 1] = 4
                return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]
            }
            """,
            to: "Sources/GizmoCore/Reader.swift",
            in: root
        )
        try TestSources.write(
            """
            func restock() -> Int {
                var shelf = Shelf()
                shelf[1] = 4
                return shelf[2]
            }
            """,
            to: "Sources/GizmoCore/Shelving.swift",
            in: root
        )
        try TestSources.write(
            """
            import GizmoCore

            public func total() -> Int {
                Limits.gap + Limits.ceiling
            }

            public func unused() {}
            """,
            to: "Sources/GizmoApp/Use.swift",
            in: root
        )
    }

    /// The built package every read-only test here shares, built once for the suite.
    static func builtFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-property-use") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    static func lookup(_ symbol: String) async throws -> String {
        try await builtFixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let freshness = try await engine.ensureFresh()
            return try await engine.lookup(symbol: symbol, freshness: freshness)
        }
    }

    @Test
    func aStoredStaticLetListsItsReadsFromItsOwnFileAnotherFileAndAnotherModule() async throws {
        let output = try await Self.lookup("Limits.ceiling")

        #expect(output.contains("semantic: fresh"))
        #expect(output.contains("reads and writes of GizmoCore.Limits.ceiling (3):"))
        #expect(output.contains("    :3  getter:margin — read  | public static var margin: Int { ceiling * 2 }"))
        #expect(output.contains("    :7  measure() — read  | return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]"))
        #expect(output.contains("    :4  total() — read  | Limits.gap + Limits.ceiling"))
        #expect(!output.contains("callers"))
    }

    @Test
    func aComputedStaticVarListsItsReadFromAnotherFile() async throws {
        let output = try await Self.lookup("Limits.margin")

        #expect(output.contains("reads and writes of GizmoCore.Limits.margin (1):"))
        #expect(output.contains("    :7  measure() — read  | return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]"))
        #expect(!output.contains("callers"))
    }

    @Test
    func aPackageStaticLetListsItsReadFromAnotherModule() async throws {
        let output = try await Self.lookup("Limits.gap")

        #expect(output.contains("reads and writes of GizmoCore.Limits.gap (2):"))
        #expect(output.contains("    :7  measure() — read  | return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]"))
        #expect(output.contains("    :4  total() — read  | Limits.gap + Limits.ceiling"))
        #expect(!output.contains("callers"))
    }

    /// Each line once, whatever the store recorded there: a compound assignment is one read-and-write site, and the implicit accessor call beside every use is never counted as a second one.
    @Test
    func anInstancePropertyListsEachLineOnceMarkedWithWhatItDoes() async throws {
        let output = try await Self.lookup("Tally.count")

        #expect(output.contains("reads and writes of GizmoCore.Tally.count (5):"))
        #expect(output.contains("    :3  measure() — write  | tally.count = 5"))
        #expect(output.contains("    :4  measure() — read and write  | tally.count += 1"))
        #expect(output.contains("    :7  measure() — read  | return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]"))
        #expect(output.contains("    :14  getter:subscript(slot:) — read  | get { count + slot }"))
        #expect(output.contains("    :15  setter:subscript(slot:) — write  | set(value) { count = value - slot }"))
        #expect(!output.contains("units"))
    }

    @Test
    func aPropertyThatIsOnlyWrittenListsTheWrite() async throws {
        let output = try await Self.lookup("Limits.budget")

        #expect(output.contains("reads and writes of GizmoCore.Limits.budget (1):"))
        #expect(output.contains("    :5  measure() — write  | Limits.budget = 2"))
    }

    /// An explicit label: `subscript(slot slot: Int)` is called `tally[slot: 1]`, so it is `subscript(slot:)` to the parser and the store alike.
    @Test
    func aSubscriptListsItsReadsAndWrites() async throws {
        let output = try await Self.lookup("Tally.subscript")

        #expect(output.contains("reads and writes of GizmoCore.Tally.subscript(slot:) (2):"))
        #expect(output.contains("    :6  measure() — write  | tally[slot: 1] = 4"))
        #expect(output.contains("    :7  measure() — read  | return Limits.ceiling + Limits.margin + tally.count + Limits.gap + tally[slot: 2]"))
        #expect(!output.contains("callers"))
    }

    /// No label: `subscript(slot: Int)` is called `shelf[1]`, so the store names it `subscript(_:)`, and it answers to its base name and to that labeled one alike.
    ///
    /// A parser that named it `subscript(slot:)`, as if it were a function, left it refused for want of a build no build could supply.
    @Test
    func anUnlabeledSubscriptListsItsReadsAndWrites() async throws {
        try await Self.builtFixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let freshness = try await engine.ensureFresh()
            let bare = try await engine.lookup(symbol: "Shelf.subscript", freshness: freshness)
            let labeled = try await engine.lookup(symbol: "Shelf.subscript(_:)", freshness: freshness)

            for output in [bare, labeled] {
                #expect(output.contains("semantic: fresh"))
                #expect(output.contains("reads and writes of GizmoCore.Shelf.subscript(_:) (2):"))
                #expect(output.contains("    :3  restock() — write  | shelf[1] = 4"))
                #expect(output.contains("    :4  restock() — read  | return shelf[2]"))
            }
        }
    }

    /// The empty case says what was looked for: "no callers" of a property is true of every property there is, and reads as dead code.
    @Test
    func aPropertyNothingUsesSaysNoReadsOrWritesWereRecorded() async throws {
        let output = try await Self.lookup("Limits.unused")

        #expect(output.contains("no reads or writes of GizmoCore.Limits.unused recorded in the store"))
        #expect(!output.contains("callers"))
    }

    /// A function and a property of one name under two owners, each queried by its owner, say of each only what was looked for in it — neither is counted under the other's word.
    @Test
    func eachOwnersQueryOfAFunctionOrAPropertySummarisesItUnderItsOwnWord() async throws {
        let function = try await Self.lookup("GizmoApp.unused")
        let property = try await Self.lookup("Limits.unused")

        #expect(function.contains("no callers of GizmoApp.unused() recorded in the store"))
        #expect(!function.contains("reads or writes"))
        #expect(property.contains("no reads or writes of GizmoCore.Limits.unused recorded in the store"))
        #expect(!property.contains("no callers"))
    }

    /// One owner holding a labeled function and a property of one name is answered once, the summary saying of each only what was looked for in it.
    @Test
    func oneOwnersFunctionAndPropertyOfOneNameAreSummarisedInOneAnswer() async throws {
        let root = try TestSources.makeTempRepo()
        let manifest = "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Meter\", targets: [.target(name: \"Meter\")])\n"
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write("public struct Gauge {\n    public var level = 0\n    public init() {}\n    public func level(of value: Int) -> Int { value }\n}\n", to: "Sources/Meter/Gauge.swift", in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "level", freshness: freshness)

        #expect(output.contains("declarations (2):"))
        #expect(!output.contains("owners"))
        #expect(output.contains("no callers of Meter.Gauge.level(of:) recorded in the store"))
        #expect(output.contains("no reads or writes of Meter.Gauge.level recorded in the store"))
        #expect(!output.contains("no callers recorded in the store for"))
    }

    /// `sift diff` resolves a changed property's sites through the same store query, so a property the store records as read is never "resolved by the index store: 0 uses".
    @Test
    func aChangedPropertysUsesInADiffAreResolvedFromTheStore() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.limits(gap: "package static let gap: Int = 7"), to: "Sources/GizmoCore/Limits.swift", in: root)
        try TestSources.commitAll(in: root, message: "annotate")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))
        let output = try await engine.diff(options: DiffOptions(range: range, member: nil, offset: 0), freshness: freshness)

        #expect(output.contains("~ Limits.gap — resolved by the index store: 2 uses"))
        #expect(output.contains("      measure() — Sources/GizmoCore/Reader.swift:7"))
        #expect(output.contains("      total() — Sources/GizmoApp/Use.swift:4"))
    }

    /// A line's units are the build units that recorded something on it, never its occurrences: `count = count + 1` from one build is a write and a read on one line, and one unit; the same line recorded by two builds is two units; and a use two builds put on different lines is drifted evidence, listed on each.
    @Test
    func aLinesUnitsAreTheBuildUnitsThatRecordedItNeverItsOccurrences() {
        func use(line: Int, unit: String, reads: Bool = false, writes: Bool = false) -> SemanticStore.Use {
            SemanticStore.Use(
                hit: SemanticStore.Hit(name: "measure()", path: "/repo/Sources/GizmoCore/Reader.swift", line: line, unit: unit),
                reads: reads,
                writes: writes
            )
        }
        let oneBuild = [use(line: 3, unit: "GizmoCore 1", writes: true), use(line: 3, unit: "GizmoCore 1", reads: true)]
        let otherBuild = [use(line: 3, unit: "GizmoCore 2", writes: true), use(line: 3, unit: "GizmoCore 2", reads: true)]

        let single = WhereRenderer.collapsedUses(oneBuild)
        let doubled = WhereRenderer.collapsedUses(oneBuild + otherBuild)
        let drifted = WhereRenderer.collapsedUses([use(line: 7, unit: "GizmoCore 1", reads: true), use(line: 8, unit: "GizmoCore 2", reads: true)])

        #expect(single.map(\.units) == [1])
        #expect(single.map(\.access) == ["read and write"])
        #expect(doubled.map(\.units) == [2])
        #expect(doubled.map(\.access) == ["read and write"])
        #expect(drifted.map(\.hit.line) == [7, 8])
        #expect(drifted.map(\.units) == [1, 1])
    }
}
