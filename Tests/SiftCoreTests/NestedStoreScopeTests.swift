//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A nested package's index store answers only for the files inside that package: a query about a file outside it is answered from another store or from syntax, never from that package's build.
@Suite(.temporaryDirectories)
struct NestedStoreScopeTests {
    /// A repository whose root is no package and has no store, with app sources outside the one nested package `Tools/Lint`, built so its store sits in `Tools/Lint/.build`.
    ///
    /// The root declares a struct and a function at `Sources/Lint/Shared.swift`, a path the nested package's own `Shared` ends with too, so a store matching by path suffix would answer the root's declarations with the package's; the last commit changes the root function's return type, and the package's tests are built.
    private static func builtFixture() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write("struct Ledger {\n    func total() -> Int { 0 }\n}\n", to: "App/Ledger.swift", in: root)
        try TestSources.write("func use() -> Int {\n    Ledger().total()\n}\n", to: "App/Use.swift", in: root)
        try TestSources.write("struct Shared {}\nfunc helper(x: Int) -> Int { x }\n", to: "Sources/Lint/Shared.swift", in: root)
        try TestSources.write("func rootUse() {\n    _ = Shared()\n    _ = helper(x: 1)\n}\n", to: "Sources/Lint/RootUse.swift", in: root)
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lint", targets: [.target(name: "Lint"), .testTarget(name: "LintTests", dependencies: ["Lint"])])
            """,
            to: "Tools/Lint/Package.swift",
            in: root
        )
        try TestSources.write("public struct Shared { public init() {} }\npublic func helper(x: Int) -> Int { x }\n", to: "Tools/Lint/Sources/Lint/Shared.swift", in: root)
        try TestSources.write("public struct Rule {\n    public init() {}\n}\n", to: "Tools/Lint/Sources/Lint/Rule.swift", in: root)
        try TestSources.write("func check() {\n    _ = Rule()\n    _ = Shared()\n    _ = helper(x: 2)\n}\n", to: "Tools/Lint/Sources/Lint/Check.swift", in: root)
        try TestSources.write(
            "@testable import Lint\nimport Testing\n\n@Test func helperWorks() {\n    #expect(helper(x: 1) == 1)\n}\n",
            to: "Tools/Lint/Tests/LintTests/HelperTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("struct Shared {}\nfunc helper(x: Int) -> Int? { x }\n", to: "Sources/Lint/Shared.swift", in: root)
        try TestSources.commitAll(in: root, message: "optional helper")
        try await TestSources.swiftBuildSuspending(packageAt: root.appendingPathComponent("Tools/Lint"), includingTests: true)
        return root
    }

    @Test
    func aQueryAboutFilesInsideAndOutsideTheNestedPackageIsAnsweredOnlyFromAStoreCoveringThem() async throws {
        let root = try await Self.builtFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let refs = WhereOptions(includeReferences: true)

        let outside = try await engine.lookup(symbol: "Ledger", freshness: engine.ensureFresh())
        let inside = try await engine.lookup(symbol: "Rule", freshness: engine.ensureFresh(), options: refs)
        let rootShared = try await engine.lookup(symbol: "Sources.Shared", freshness: engine.ensureFresh(), options: refs)
        let lintShared = try await engine.lookup(symbol: "Lint.Shared", freshness: engine.ensureFresh(), options: refs)

        #expect(outside.contains("semantic: none (no index store covers these files; Tools/Lint/.build answers only for files in Tools/Lint)"), "\(outside)")
        #expect(outside.contains("build the files' own project for its store"), "\(outside)")
        #expect(!outside.contains("passed over"), "\(outside)")
        #expect(!outside.contains("not found in the store"), "\(outside)")
        #expect(inside.contains("semantic: fresh"), "\(inside)")
        #expect(inside.contains("Tools/Lint/Sources/Lint/Check.swift (1):"), "\(inside)")
        // Listed by written name, the package's same-named struct's use among them, never as a reference the store resolved.
        #expect(rootShared.contains("semantic: none"), "\(rootShared)")
        #expect(!rootShared.contains("references to Sources.Shared"), "\(rootShared)")
        #expect(rootShared.contains("Sources/Lint/RootUse.swift (1):"), "\(rootShared)")
        #expect(lintShared.contains("semantic: fresh"), "\(lintShared)")
        #expect(lintShared.contains("Tools/Lint/Sources/Lint/Check.swift (1):"), "\(lintShared)")
    }

    @Test
    func aBareNameSpanningBothSidesRefusesTheRootDeclarationAsOutsideThePackageWithNoBuildAdvice() async throws {
        let root = try await Self.builtFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let shared = try await engine.lookup(symbol: "Shared", freshness: engine.ensureFresh())

        #expect(shared.contains("outside the store's package (Tools/Lint)"), "\(shared)")
        #expect(!shared.contains("build this target"), "\(shared)")
        #expect(!shared.contains("no build in the store covers its file"), "\(shared)")
    }

    @Test
    func diffAndAffectedMatchTheRootFunctionByNameRatherThanResolvingItToThePackagesFunction() async throws {
        let root = try await Self.builtFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let diff = try await engine.diff(
            options: DiffOptions(range: DiffRange.resolve("HEAD~1..HEAD", git: GitContext(repoRoot: root))),
            freshness: engine.ensureFresh()
        )
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        #expect(!diff.contains("resolved by the index store"), "\(diff)")
        #expect(diff.contains("its file lies outside the store's package, Tools/Lint"), "\(diff)")
        #expect(diff.contains("Sources/Lint/RootUse.swift:3"), "\(diff)")
        #expect(affected.contains("outside the store's package (Tools/Lint)"), "\(affected)")
        #expect(!affected.split(separator: "\n").contains { $0.contains("helperWorks() — 1 hop") && !$0.contains("name match") }, "\(affected)")
    }
}
