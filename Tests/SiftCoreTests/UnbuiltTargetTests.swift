//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A store built with `swift build --target Core` holds nothing from the package's other targets, so an answer about a name one of them writes says `partial` and names the target with how many of its lines write the name.
///
/// Its count clauses name the target too. A target that writes none of the asked names, or one SwiftPM builds for the host (`.plugin`, `.macro`), leaves the answer `fresh`.
@Suite(.serialized, .temporaryDirectories)
struct UnbuiltTargetTests {
    private static func gizmo(_ targets: [String], lines: Int) -> TargetsNotBuilt {
        TargetsNotBuilt(names: targets, lines: lines, written: ["Gizmo"])
    }

    @Test
    func aTargetNotBuiltIsNamedWithTheLinesThatWriteTheName() {
        #expect(SemanticAxis.partial(testFiles: 0, targets: Self.gizmo(["Extra"], lines: 2)).rendered == "partial (target Extra not built — 2 lines there name Gizmo, not counted)")
        #expect(SemanticAxis.partial(testFiles: 0, targets: Self.gizmo(["Extra"], lines: 1)).rendered == "partial (target Extra not built — 1 line there names Gizmo, not counted)")
        #expect(SemanticAxis.partial(testFiles: 0, targets: Self.gizmo(["Extra", "Other"], lines: 5)).rendered == "partial (targets Extra, Other not built — 5 lines there name Gizmo, not counted)")
        #expect(SemanticAxis.partial(testFiles: 0, targets: TargetsNotBuilt(names: ["Extra"], lines: 3, written: ["Gizmo", "init"])).rendered
            == "partial (target Extra not built — 3 lines there name Gizmo or init, not counted)")
    }

    @Test
    func filesAloneKeepTheirClause() {
        #expect(SemanticAxis.partial(testFiles: 2).rendered == "partial (2 test files have no unit in the store — references from tests are a lower bound)")
        #expect(SemanticAxis.of(refusals: [], occurrences: [], testFilesWithoutUnit: 1).rendered == "partial (1 test file has no unit in the store — references from tests are a lower bound)")
    }

    @Test
    func targetsAndTestFilesShareOneParenthesis() {
        #expect(SemanticAxis.of(refusals: [], occurrences: [], testFilesWithoutUnit: 3, targetsNotBuilt: Self.gizmo(["Extra"], lines: 2)).rendered
            == "partial (target Extra not built — 2 lines there name Gizmo, not counted; 3 test files have no unit in the store — references from tests are a lower bound)")
    }

    @Test
    func pastThreeTargetsTheRestAreCounted() {
        #expect(SemanticAxis.partial(testFiles: 0, targets: Self.gizmo(["Alpha", "Beta", "Gamma", "Delta", "Epsilon"], lines: 9)).rendered
            == "partial (targets Alpha, Beta, Gamma +2 more not built — 9 lines there name Gizmo, not counted)")
    }

    @Test
    func staleOutranksAndUnresolvedYieldsToTargetsNotBuilt() {
        let changed = SemanticRefusal(path: "Sources/Core/A.swift", reason: .modifiedSinceBuild, symbol: "Core.A", kind: .structKind)
        let unresolved = SemanticRefusal(path: "Sources/Core/B.swift", reason: .noCoveringUnit, symbol: "Core.B", kind: .structKind)

        #expect(SemanticAxis.of(refusals: [changed], occurrences: [], targetsNotBuilt: Self.gizmo(["Extra"], lines: 1)).rendered.hasPrefix("stale since last build"))
        #expect(SemanticAxis.of(refusals: [unresolved], occurrences: [], targetsNotBuilt: Self.gizmo(["Extra"], lines: 1)).rendered == "partial (target Extra not built — 1 line there names Gizmo, not counted)")
        #expect(SemanticAxis.of(refusals: [unresolved], occurrences: []).rendered == "fresh, 1 declaration not found in the store")
    }

    @Test
    func pluginAndMacroTargetsAreReadAsHostBuilt() {
        let manifest = SwiftPMManifest.parse(source: """
        let package = Package(name: "P", targets: [
            .target(name: "Lib"),
            .macro(name: "Macros", dependencies: []),
            .plugin(name: "Fmt", capability: .command(intent: .custom(verb: "fmt", description: "x")), path: "Plugins/Fmt"),
            .testTarget(name: "LibTests"),
        ])
        """)

        #expect(manifest.hostBuiltTargets == ["Macros", "Fmt"])
    }

    /// The reported case: `Extra` calls `A.f` and `A.k`, extends `A` and takes one as a parameter, and was never built, so `where` saw one caller and three uses under `fresh`.
    @Test
    func aPackageBuiltForOneTargetNamesTheOtherWhereItWritesTheName() async throws {
        let root = try Self.twoTargetPackage()
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Core"])

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let callers = try await engine.lookup(symbol: "A.f", freshness: engine.ensureFresh())
        let uses = try await engine.lookup(symbol: "A", freshness: engine.ensureFresh())
        let none = try await engine.lookup(symbol: "A.k", freshness: engine.ensureFresh())

        #expect(callers.contains("semantic: partial (target Extra not built — 1 line there names f, not counted)"), "\(callers)")
        #expect(!callers.contains("semantic: fresh"), "\(callers)")
        #expect(uses.contains("semantic: partial (target Extra not built — 2 lines there name A, not counted)"), "\(uses)")
        #expect(uses.contains("1 production, a lower bound (target Extra not built)"), "\(uses)")
        #expect(none.contains("no callers of Core.A.k() recorded in the store; not counting target Extra, which is not built"), "\(none)")
    }

    /// `Extra` never writes `h` or `B`, so a store that never built it hides nothing from either answer.
    @Test
    func aTargetNotBuiltThatNeverWritesTheNameLeavesTheAnswerFresh() async throws {
        let root = try Self.twoTargetPackage()
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Core"])

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let type = try await engine.lookup(symbol: "B", freshness: engine.ensureFresh())
        let member = try await engine.lookup(symbol: "A.h", freshness: engine.ensureFresh())

        #expect(member.contains("no callers of Core.A.h() recorded in the store\n"), "\(member)")
        for answer in [type, member] {
            #expect(answer.contains("semantic: fresh\n"), "\(answer)")
            #expect(!answer.contains("not built"), "\(answer)")
        }
    }

    @Test
    func aPackageWithEveryTargetBuiltReadsFresh() async throws {
        let root = try Self.twoTargetPackage()
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let callers = try await engine.lookup(symbol: "A.f", freshness: engine.ensureFresh())
        let none = try await engine.lookup(symbol: "A.h", freshness: engine.ensureFresh())

        #expect(callers.contains("semantic: fresh\n"), "\(callers)")
        #expect(!callers.contains("not built"), "\(callers)")
        #expect(none.contains("no callers of Core.A.h() recorded in the store\n"), "\(none)")
    }

    /// A command plugin is compiled for the host without an index store, so no build records a unit for it: a fully built package reads `fresh`, even about a name the plugin writes.
    @Test
    func aPluginTargetIsNeverNamedAsNotBuilt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Probe",
                targets: [
                    .target(name: "Lib"),
                    .plugin(name: "Fmt", capability: .command(intent: .custom(verb: "fmt", description: "x")), path: "Plugins/Fmt"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Gizmo {\n    public var arguments: [String] = []\n    public init() {}\n}\n\npublic func begin() -> [String] {\n    Gizmo().arguments\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write(
            "import PackagePlugin\n\n@main\nstruct Fmt: CommandPlugin {\n    func performCommand(context: PluginContext, arguments: [String]) async throws {\n        _ = arguments\n    }\n}\n",
            to: "Plugins/Fmt/Fmt.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let type = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh())
        let written = try await engine.lookup(symbol: "Gizmo.arguments", freshness: engine.ensureFresh())

        for answer in [type, written] {
            #expect(answer.contains("semantic: fresh\n"), "\(answer)")
            #expect(!answer.contains("not built"), "\(answer)")
        }
    }

    /// `Extra` uses `A` through an operator, a call, a subscript and members of a lowercase value, none spelling a name the scan could pair with the declaration, so each answer names it.
    @Test
    func aUseTheScanCannotSeeStillNamesTheTargetNotBuilt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Probe",
                targets: [.target(name: "Core"), .target(name: "Extra", dependencies: ["Core"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct A {
                public init() {}
                public static func + (lhs: A, rhs: A) -> A { lhs }
                public func callAsFunction() {}
                public subscript(_ index: Int) -> Int { index }
                public func g(_ value: Int) {}
                public func f() -> Int { 0 }
            }
            """,
            to: "Sources/Core/A.swift",
            in: root
        )
        try TestSources.write(
            "import Core\n\nfunc finish(_ a: A) {\n    _ = a + a\n    a()\n    _ = a[0]\n    let h: (Int) -> Void = a.g\n    let k = a.f\n    _ = (h, k)\n}\n",
            to: "Sources/Extra/Extra.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Core"])

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        for member in ["+", "callAsFunction", "subscript"] {
            let answer = try await engine.lookup(symbol: "A.\(member)", freshness: engine.ensureFresh())
            #expect(answer.contains("semantic: partial (target Extra not built — its uses of A.\(member) cannot be found by name, not counted)"), "\(answer)")
        }
        for member in ["g", "f"] {
            let answer = try await engine.lookup(symbol: "A.\(member)", freshness: engine.ensureFresh())
            #expect(answer.contains("semantic: partial (target Extra not built — 1 line there names \(member), not counted)"), "\(answer)")
        }
    }

    @Test
    func severalTargetsAreNamedForAnUnspelledUse() {
        let targets = TargetsNotBuilt(names: ["Extra", "Other"], lines: 0, written: [], unfindable: ["A.subscript"])

        #expect(SemanticAxis.partial(testFiles: 0, targets: targets).rendered == "partial (targets Extra, Other not built — its uses of A.subscript cannot be found by name, not counted)")
    }

    /// A package of a library `Core` declaring `A` and `B`, and a target `Extra` that calls `A.f` and `A.k`, extends `A` and takes one as a parameter.
    private static func twoTargetPackage() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Probe",
                targets: [.target(name: "Core"), .target(name: "Extra", dependencies: ["Core"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            "public struct A {\n    public init() {}\n    public func f() {}\n    public func h() {}\n    public func k() {}\n}\n\npublic struct B {}\n\npublic func begin() {\n    A().f()\n}\n",
            to: "Sources/Core/A.swift",
            in: root
        )
        try TestSources.write("import Core\n\nextension A {\n    func g() {}\n}\n\nfunc finish(_ a: A) {\n    a.f()\n    a.k()\n}\n", to: "Sources/Extra/Extra.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }
}
