//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what the after-edit walk must still reach, being a lower bound: a test only seeding every declaration of the changed file would reach, through a declaration whose callers never spell its name.
@Suite(.serialized, .temporaryDirectories)
struct AffectedAfterEditReachTests {
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

    private static let sources: [Source] = [
        // An operator in a type, applied by its symbol.
        Source(path: "Money.swift", built: """
        struct Money: Equatable {
            let cents: Int
            static func == (lhs: Money, rhs: Money) -> Bool { lhs.cents == rhs.cents }
        }
        """, edit: ("lhs.cents == rhs.cents }", "lhs.cents == rhs.cents && true }")),
        // An operator at file scope, which no type declares.
        Source(path: "Meter.swift", built: """
        struct Meter {
            let value: Int
        }

        func + (lhs: Meter, rhs: Meter) -> Meter { Meter(value: lhs.value + rhs.value) }
        """, edit: ("lhs.value + rhs.value", "rhs.value + lhs.value")),
        // A witness the language calls in an interpolation.
        Source(path: "Badge.swift", built: """
        struct Badge: CustomStringConvertible {
            var description: String { "badge" }
        }
        """, edit: ("\"badge\"", "\"badge!\"")),
        Source(path: "Handler.swift", built: "typealias Handler = (Int) -> Int\n", edit: ("-> Int", "-> Int?")),
        // A property wrapper, whose wrapped value is read behind the property it wraps.
        Source(path: "Clamped.swift", built: """
        @propertyWrapper
        struct Clamped {
            private var stored = 0
            var wrappedValue: Int {
                get { min(stored, 10) }
                set { stored = newValue }
            }
        }
        """, edit: ("min(stored, 10)", "min(stored, 9)")),
        Source(path: "Box.swift", built: """
        struct Box {
            @Clamped var level: Int
        }
        """),
        // A stored property's default, which synthesized `Codable` reads without spelling it.
        Source(path: "Config.swift", built: """
        struct Config: Codable {
            var retries = 3
        }
        """, edit: ("= 3", "= 5")),
        // A function handed on as a value, here and through a helper.
        Source(path: "Gate.swift", built: """
        struct Gate {
            func gate(open: Bool) -> Bool { open }
        }
        """, edit: ("{ open }", "{ open && true }")),
        Source(path: "Relay.swift", built: "func opened(_ flag: Bool) -> Bool { Gate().gate(open: flag) }\n"),
        // A function called only as an implicit member, renamed at its declaration with its one call site still to follow.
        Source(path: "Door.swift", built: """
        enum Motion {
            case still, moving
            static func swing(open: Bool) -> Motion { open ? .moving : .still }
        }

        struct Door {
            func apply(_ motion: Motion) -> Bool { motion == .moving }
        }
        """, edit: ("func swing(open", "func pivot(open")),
        Source(path: "Porch.swift", built: "func swingDoor() -> Bool { Door().apply(.swing(open: true)) }\n"),
        // A same-named property of another type, its bare name no site of the function.
        Source(path: "Fence.swift", built: "struct Fence {\n    var gate = true\n}\n"),
        // A computed property with a site of its own, reached by its name alone: its type is no seed.
        Source(path: "Tally.swift", built: """
        struct Tally {
            var count = 0
            var doubled: Int { count * 2 }
        }
        """, edit: ("count * 2", "count + count")),
        Source(path: "Report.swift", built: "func report() -> Int { Tally().doubled }\n"),
    ]

    /// One suite per case, each reaching its case's edited declaration and nothing else.
    private static let suites: [(name: String, body: String)] = [
        ("MoneyTests", "@Test func equal() { #expect(Money(cents: 1) == Money(cents: 1)) }"),
        ("MeterTests", "@Test func sum() { #expect((Meter(value: 1) + Meter(value: 2)).value == 3) }"),
        ("BadgeTests", "@Test func label() { #expect(\"\\(Badge())\" == \"badge\") }"),
        ("HandlerTests", "@Test func doubles() { let twice: Handler = { $0 * 2 }; #expect(twice(2) == 4) }"),
        ("ClampTests", "@Test func clamps() { var box = Box(); box.level = 12; #expect(box.level == 10) }"),
        ("ConfigTests", "@Test func encodes() throws { #expect(try !JSONEncoder().encode(Config()).isEmpty) }"),
        ("RefTests", "@Test func maps() { #expect([true].map(Gate().gate(open:)) == [true]) }"),
        ("RelayTests", "@Test func relays() { #expect([true].map(opened(_:)) == [true]) }"),
        ("DoorTests", "@Test func swings() { #expect(swingDoor()) }"),
        ("FenceTests", "@Test func shut() { #expect(Fence().gate) }"),
        ("TallyTests", "@Test func starts() { #expect(Tally().count == 0) }"),
    ]

    private static func makeEditedRepo(sources: [Source] = Self.sources, suites: [(name: String, body: String)] = Self.suites) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest, to: "Package.swift", in: root)
        for source in sources {
            try TestSources.write(source.built + "\n", to: "Sources/Lib/\(source.path)", in: root)
        }
        for suite in suites {
            try TestSources.write("import Foundation\nimport Testing\n@testable import Lib\n\nstruct \(suite.name) {\n    \(suite.body)\n}\n", to: "Tests/LibTests/\(suite.name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        // The edits, written after the build, as an edit leaves them.
        for source in sources {
            guard let edit = source.edit else { continue }
            let edited = source.built.replacingOccurrences(of: edit.from, with: edit.to)
            try TestSources.write(edited + "\n", to: "Sources/Lib/\(source.path)", in: root)
        }
        return root
    }

    private static func affected(_ root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// One fixture for every case, since each needs a build: each suite reaches its edited declaration only through a site that never spells the declaration's name as a call.
    @Test
    func anEditBeforeTheRebuildReachesTestsThatNeverCallTheEditedName() async throws {
        let root = try await Self.makeEditedRepo()

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        // An operator in a type seeds the type, applied wherever the operator is.
        #expect(output.contains("LibTests.MoneyTests/equal() — 1 hop"))
        // A file-scope operator leaves no identifier to seed from, so its file is seeded whole.
        #expect(output.contains("LibTests.MeterTests/sum() — 1 hop"))
        // A witness the language calls seeds the type declaring it.
        #expect(output.contains("LibTests.BadgeTests/label() — 1 hop"))
        // A typealias is reached where it is written as a type.
        #expect(output.contains("LibTests.HandlerTests/doubles() — 1 hop"))
        // A wrapper's wrapped value seeds the wrapper, reached at `@Clamped` and on through the property it wraps.
        #expect(output.contains("LibTests.ClampTests/clamps() — 2 hops"))
        // A stored property seeds its type, which the memberwise initializer and `Codable` read without spelling the property.
        #expect(output.contains("LibTests.ConfigTests/encodes() — 1 hop"))
        // A function handed on as a value is a site of it, at the first hop and at every hop after.
        #expect(output.contains("LibTests.RefTests/maps() — 1 hop"))
        #expect(output.contains("LibTests.RelayTests/relays() — 2 hops"))
        // A function called only as an implicit member is reached by the name its call site still spells.
        #expect(output.contains("LibTests.DoorTests/swings() — 2 hops"))
        // A function's bare name with no call is no site of it, and a computed property seeds only its own name: neither reaches a test that spells only the other type, or the property's type.
        #expect(!output.contains("FenceTests"))
        #expect(!output.contains("TallyTests"))
        // The note names only the seeds the walk scanned: the operators are none, and the file-scope operator's file is not among those seeded from the diff.
        #expect(output.contains("after-edit walk — syntactic, lower bound: the 8 files changed since the build were seeded from the 12 names the diff touched there (Badge, Clamped, Config, Handler, Money, description, doubled, gate, +4 more)"))
        #expect(!output.contains("(==") && !output.contains(", ==") && !output.contains(", +,"))
    }
}

extension AffectedAfterEditReachTests {
    /// A file edited and committed after the build, then edited again: the diff against `HEAD` shows only the second edit, so the file is seeded whole and the first edit's declaration still reaches its test.
    @Test
    func aFileCommittedSinceTheBuildIsSeededWholeSoTheCommittedEditIsNotLost() async throws {
        let root = try TestSources.makeTempRepo()
        let toplevel = try TestSources.runGit(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: toplevel).resolvingSymlinksInPath().path == root.path)
        let built = "func alpha() -> Int { 1 }\n\nfunc beta() -> Int { 2 }\n"
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write(built, to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct AlphaTests {\n    @Test func first() { #expect(alpha() == 1) }\n}\n", to: "Tests/LibTests/AlphaTests.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct BetaTests {\n    @Test func second() { #expect(beta() == 2) }\n}\n", to: "Tests/LibTests/BetaTests.swift", in: root)
        // Dated well before the build, so only the later commit is newer than it.
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "fixture"], in: root, dated: Date(timeIntervalSinceNow: -7200))
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        let alphaEdited = built.replacingOccurrences(of: "{ 1 }", with: "{ 10 }")
        try TestSources.write(alphaEdited, to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "edit alpha"], in: root, dated: Date(timeIntervalSinceNow: 3600))
        try TestSources.write(alphaEdited.replacingOccurrences(of: "{ 2 }", with: "{ 20 }"), to: "Sources/Lib/Pair.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.AlphaTests/first()"))
        #expect(output.contains("LibTests.BetaTests/second()"))
        #expect(output.contains("seeded whole: committed since the build: Sources/Lib/Pair.swift"))
    }
}

extension AffectedAfterEditReachTests {
    /// A declaration no site names is reached through the outermost type declaring it, and an added enum case through its enum even where its name has sites of its own.
    @Test
    func aDeclarationNoSiteNamesIsReachedThroughItsOutermostType() async throws {
        let sources = [
            // An added case, its name written elsewhere as another type's property.
            Source(path: "Kind.swift", built: "enum Kind: CaseIterable {\n    case small\n    case medium\n}", edit: ("case medium", "case medium\n    case large")),
            Source(path: "Shirt.swift", built: "struct Shirt {\n    var large = false\n}\n\nfunc isLarge() -> Bool { Shirt().large }"),
            // A decoding initializer, reached through `Point.self`, which calls no initializer by name.
            Source(path: "Point.swift", built: """
            struct Point: Decodable {
                let x: Int

                init(from decoder: Decoder) throws {
                    x = try decoder.singleValueContainer().decode(Int.self)
                }
            }
            """, edit: ("decode(Int.self)", "decode(Int.self) + 0")),
            // A coding key's raw value, reached through the type the keys are nested in.
            Source(path: "Tag.swift", built: """
            struct Tag: Codable {
                let label: String

                enum CodingKeys: String, CodingKey {
                    case label = "name"
                }
            }
            """, edit: ("= \"name\"", "= \"title\"")),
            // A witness the standard library reads, on no list of them.
            Source(path: "Countdown.swift", built: """
            struct Countdown: Sequence, IteratorProtocol {
                var left = 3
                var underestimatedCount: Int { 3 }

                mutating func next() -> Int? {
                    left -= 1
                    return left < 0 ? nil : left
                }
            }
            """, edit: ("Int { 3 }", "Int { 2 }")),
        ]
        let suites = [
            ("KindTests", "@Test func counts() { #expect(Kind.allCases.count == 2) }"),
            ("PointTests", "@Test func decodes() throws { #expect(try JSONDecoder().decode(Point.self, from: Data()).x == 1) }"),
            ("TagTests", "@Test func decodes() { #expect((try? JSONDecoder().decode(Tag.self, from: Data())) == nil) }"),
            ("CountTests", "@Test func counts() { #expect(Array(Countdown()).count == 3) }"),
        ]
        let root = try await Self.makeEditedRepo(sources: sources, suites: suites)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.KindTests/counts() — 1 hop"))
        #expect(output.contains("LibTests.PointTests/decodes() — 1 hop"))
        #expect(output.contains("LibTests.TagTests/decodes() — 1 hop"))
        #expect(output.contains("LibTests.CountTests/counts() — 1 hop"))
    }

    /// A checkout since the build brings in an older commit's text, which no commit time newer than the build dates: every refused file is seeded whole, and the note says why.
    @Test
    func aCheckoutSinceTheBuildSeedsEveryRefusedFileWhole() async throws {
        let root = try TestSources.makeTempRepo()
        let toplevel = try TestSources.runGit(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: toplevel).resolvingSymlinksInPath().path == root.path)
        let built = "func alpha() -> Int { 1 }\n\nfunc beta() -> Int { 2 }\n"
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write(built, to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct AlphaTests {\n    @Test func first() { #expect(alpha() == 1) }\n}\n", to: "Tests/LibTests/AlphaTests.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct BetaTests {\n    @Test func second() { #expect(beta() == 2) }\n}\n", to: "Tests/LibTests/BetaTests.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "fixture"], in: root, dated: Date(timeIntervalSinceNow: -7200))
        try TestSources.runGit(["branch", "older"], in: root)
        try TestSources.write(built.replacingOccurrences(of: "{ 1 }", with: "{ 10 }"), to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "edit alpha"], in: root, dated: Date(timeIntervalSinceNow: -3600))
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        // Back to the older commit after the build, then an edit: the diff against `HEAD` shows only `beta`, and the file's last commit predates the build.
        try TestSources.runGit(["checkout", "older"], in: root, dated: Date(timeIntervalSinceNow: 3600))
        try TestSources.write(built.replacingOccurrences(of: "{ 2 }", with: "{ 20 }"), to: "Sources/Lib/Pair.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.AlphaTests/first()"))
        #expect(output.contains("LibTests.BetaTests/second()"))
        #expect(output.contains("seeded whole: HEAD moved since the build: Sources/Lib/Pair.swift"))
    }

    /// A commit in the build's own second: git floors its time to the second and the anchor is fractional, so it counts as after the build.
    @Test
    func aCommitInTheBuildsOwnSecondCountsAsSinceTheBuild() async throws {
        let root = try TestSources.makeTempRepo()
        let toplevel = try TestSources.runGit(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: toplevel).resolvingSymlinksInPath().path == root.path)
        let built = "func alpha() -> Int { 1 }\n\nfunc beta() -> Int { 2 }\n"
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write(built, to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct AlphaTests {\n    @Test func first() { #expect(alpha() == 1) }\n}\n", to: "Tests/LibTests/AlphaTests.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "fixture"], in: root, dated: Date(timeIntervalSinceNow: -7200))
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        let discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        let newestUnit = try #require(discovery.discover()?.newestUnit)
        let anchorSecond = SemanticContext.buildAnchor(newestUnit: newestUnit).rounded(.down)
        let alphaEdited = built.replacingOccurrences(of: "{ 1 }", with: "{ 10 }")
        try TestSources.write(alphaEdited, to: "Sources/Lib/Pair.swift", in: root)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "edit alpha"], in: root, dated: Date(timeIntervalSince1970: anchorSecond))
        try TestSources.write(alphaEdited.replacingOccurrences(of: "{ 2 }", with: "{ 20 }"), to: "Sources/Lib/Pair.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.AlphaTests/first()"))
        #expect(output.contains("seeded whole: committed since the build: Sources/Lib/Pair.swift"))
    }

    /// A file-scope operator beside an edited function: the operator leaves no name to scan for, so its file is seeded whole however many other changes do.
    @Test
    func aFileScopeOperatorSeedsItsFileWholeBesideAnotherChange() async throws {
        let sources = [
            Source(path: "Vec.swift", built: """
            struct Vec {
                let x: Int
            }

            func + (lhs: Vec, rhs: Vec) -> Vec { Vec(x: lhs.x + rhs.x) }

            func helper() -> Int { 1 }
            """, edit: ("lhs.x + rhs.x) }\n\nfunc helper() -> Int { 1 }", "rhs.x + lhs.x) }\n\nfunc helper() -> Int { 2 }")),
        ]
        let suites = [
            ("VecTests", "@Test func sum() { #expect((Vec(x: 1) + Vec(x: 2)).x == 3) }"),
            ("HelperTests", "@Test func one() { #expect(helper() == 1) }"),
        ]
        let root = try await Self.makeEditedRepo(sources: sources, suites: suites)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.VecTests/sum()"))
        #expect(output.contains("LibTests.HelperTests/one()"))
    }

    /// A function passed by its bare name is a site of it; another type's same-named property and a local binding spelling the name are not.
    @Test
    func aFunctionPassedByItsBareNameIsASiteOfIt() async throws {
        let sources = [
            Source(path: "Fmt.swift", built: "func double(_ value: Int) -> Int { value * 2 }", edit: ("value * 2", "value + value")),
            Source(path: "Mixer.swift", built: "struct Mixer {\n    var double = 1\n}"),
        ]
        let suites = [
            ("FmtTests", "@Test func doubles() { #expect([1].map(double) == [2]) }"),
            ("MixTests", "@Test func level() { #expect(Mixer().double == 1) }"),
            ("ShadowTests", "@Test func local() { let double = 2; #expect([double].count == 1) }"),
        ]
        let root = try await Self.makeEditedRepo(sources: sources, suites: suites)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("LibTests.FmtTests/doubles() — 1 hop"))
        #expect(!output.contains("MixTests"))
        #expect(!output.contains("ShadowTests"))
    }
}

private extension AffectedAfterEditReachTests {
    /// One source file, as built, and the one-line edit made to it after the build.
    struct Source {
        let path: String
        let built: String
        var edit: (from: String, to: String)?
    }
}
