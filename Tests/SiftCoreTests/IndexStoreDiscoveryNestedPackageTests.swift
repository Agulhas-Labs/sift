//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A SwiftPM build of a package nested below the repo root (`swift build --package-path <Pkg> --build-tests`) leaves its store in `<Pkg>/.build`, and discovery finds it with no `indexStorePath` set.
@Suite(.temporaryDirectories)
struct IndexStoreDiscoveryNestedPackageTests {
    /// A store shape — a versioned `units` directory holding one unit written at `date` — which is all discovery reads.
    private static func makeStore(at url: URL, builtAt date: Date = Date()) throws {
        let unit = url.appendingPathComponent("v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: unit)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
    }

    private static func discovery(in root: URL, packages: [String]) -> IndexStoreDiscovery {
        var discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        discovery.packageDirectories = packages
        return discovery
    }

    private static func makeRepo() throws -> URL {
        try TemporaryDirectory.make("nested-package-store")
    }

    @Test
    func statusFindsTheStoreOfANestedPackageBuiltTheDocumentedWay() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\n", to: "Kit/Package.swift", in: root)
        try TestSources.write("func helper() {}\n", to: "Kit/Sources/Lib/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try Self.makeStore(at: root.appendingPathComponent("Kit/.build/out"))
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("Kit/.build/out"))
        #expect(!status.contains("index store: none found"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift.json").path))
    }

    @Test
    func theNativeLayoutAndAScratchPathOfANestedPackageAreProbedToo() throws {
        let native = try Self.makeRepo()
        try Self.makeStore(at: native.appendingPathComponent("Kit/.build/debug/index/store"))
        let scratch = try Self.makeRepo()
        try Self.makeStore(at: scratch.appendingPathComponent("Kit/.build/warden/out"))

        let fromNative = Self.discovery(in: native, packages: ["Kit"]).discover()
        let fromScratch = Self.discovery(in: scratch, packages: ["Kit"]).discover()

        #expect(fromNative?.path.path.hasSuffix("Kit/.build/debug/index/store") == true)
        #expect(fromNative?.provenance == .swiftPMBuild)
        #expect(fromScratch?.path.path.hasSuffix("Kit/.build/warden/out") == true)
    }

    @Test
    func theNewestStoreWinsBetweenNestedPackages() throws {
        let root = try Self.makeRepo()
        try Self.makeStore(at: root.appendingPathComponent("A/.build/out"), builtAt: Date(timeIntervalSinceNow: -3600))
        try Self.makeStore(at: root.appendingPathComponent("B/.build/out"), builtAt: Date())

        let discovered = Self.discovery(in: root, packages: ["A", "B"]).discover()

        #expect(discovered?.path.path.hasSuffix("B/.build/out") == true)
    }

    @Test
    func theRootsOwnStoreIsKeptWhereANestedOneIsNewer() throws {
        let root = try Self.makeRepo()
        try Self.makeStore(at: root.appendingPathComponent(".build/out"), builtAt: Date(timeIntervalSinceNow: -3600))
        try Self.makeStore(at: root.appendingPathComponent("Kit/.build/out"), builtAt: Date())

        let expected = root.appendingPathComponent(".build/out").resolvingSymlinksInPath().path
        let discovered = Self.discovery(in: root, packages: ["Kit"]).discover()

        #expect(discovered?.path.resolvingSymlinksInPath().path == expected)
    }

    @Test
    func aNestedPackageInsideAnotherCheckoutIsPassedOver() throws {
        let root = try Self.makeRepo()
        let inner = root.appendingPathComponent("Inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere/.git/worktrees/inner".utf8).write(to: inner.appendingPathComponent(".git"))
        try Self.makeStore(at: inner.appendingPathComponent("Kit/.build/out"))

        let discovered = Self.discovery(in: root, packages: ["Inner/Kit"]).discover()

        #expect(discovered?.path == nil)
    }

    @Test
    func aNestedStoreCarriesItsPackageAndStatusLabelsItRelativeToThePackage() throws {
        let nested = try Self.makeRepo()
        try Self.makeStore(at: nested.appendingPathComponent("Kit/.build/out"))
        let root = try Self.makeRepo()
        try Self.makeStore(at: root.appendingPathComponent(".build/out"))

        let fromNested = try #require(Self.discovery(in: nested, packages: ["Kit"]).discover())
        let fromRoot = try #require(Self.discovery(in: root, packages: ["Kit"]).discover())
        let line = SiftEngine.storeStatusLine(discovered: fromNested, rejected: [])

        #expect(fromNested.package == "Kit")
        #expect(fromRoot.package.isEmpty)
        #expect(line.hasPrefix("index store: Kit/.build — "), "\(line)")
        #expect(SiftEngine.storeStatusLine(discovered: fromRoot, rejected: []).hasPrefix("index store: .build — "))
    }

    @Test
    func aStaleRefusalForANestedStoreNamesThePackagePath() throws {
        let nested = try Self.makeRepo()
        try Self.makeStore(at: nested.appendingPathComponent("Kit/.build/out"))
        let discovered = try #require(Self.discovery(in: nested, packages: ["Kit"]).discover())
        let source = try #require(SemanticRefusal.Rebuild(provenance: discovered.provenance, package: discovered.package, imports: []))
        let test = try #require(SemanticRefusal.Rebuild(provenance: discovered.provenance, package: discovered.package, imports: ["Testing"]))

        #expect(SemanticRefusal.Reason.modifiedSinceBuild.instruction(rebuild: source) == "; rebuild with `sift run -- swift build --package-path Kit`, then retry")
        #expect(SemanticRefusal.Reason.modifiedSinceBuild.instruction(rebuild: test) == "; rebuild with `sift run -- swift build --package-path Kit --build-tests`, then retry")
        #expect(SemanticRefusal.Reason.noCoveringUnit.instruction(rebuild: test).contains("`sift run -- swift build --package-path Kit --build-tests`"))
        #expect(SemanticRefusal.Rebuild.covering([refusal(source), refusal(test)]) == test)
    }

    @Test
    func aUsageLineForANestedStoreNamesThePackagePath() {
        let nested = TestFileCoverage(withoutUnit: 2, neverBuilt: true, provenance: .swiftPMBuild, package: "Kit")

        #expect(nested.build == "build with `sift run -- swift build --package-path Kit --build-tests`")
    }

    @Test
    func aRootStoresAdviceIsUnchanged() {
        let root = TestFileCoverage(withoutUnit: 2, neverBuilt: true, provenance: .swiftPMBuild)
        let rebuild = SemanticRefusal.Rebuild(provenance: .swiftPMBuild, imports: ["Testing"])

        #expect(root.build == "build with `sift run -- swift build --build-tests`")
        #expect(SemanticRefusal.Reason.modifiedSinceBuild.instruction(rebuild: rebuild) == "; rebuild with `sift run -- swift build --build-tests`, then retry")
        #expect(SemanticRefusal.Reason.modifiedSinceBuild.instruction(rebuild: SemanticRefusal.Rebuild(provenance: .swiftPMBuild, imports: [])) == "; rebuild with `sift run -- swift build`, then retry")
    }

    @Test
    func refusalsFromDifferentPackagesShareNoRebuild() {
        let kit = SemanticRefusal.Rebuild.swiftPM(buildTests: false, package: "Kit")
        let other = SemanticRefusal.Rebuild.swiftPM(buildTests: false, package: "Other")

        #expect(SemanticRefusal.Rebuild.covering([refusal(kit), refusal(other)]) == nil)
    }

    /// A package nested at `Kit` with one test, built the documented way, so its store sits in `Kit/.build` and the repository root holds no manifest; the library changes after the commit so `affected` has a declaration to walk from.
    private static func builtNestedFixture() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Kit",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Kit/Package.swift",
            in: root
        )
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Kit/Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            "import Lib\nimport Testing\n\n@Suite struct WidgetTests {\n    @Test func builds() { _ = Widget() }\n}\n",
            to: "Kit/Tests/LibTests/WidgetTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Kit/Sources/Lib/Core.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root.appendingPathComponent("Kit"), includingTests: true)
        return root
    }

    @Test
    func affectedAndWhereForANestedStoreNameThePackageInTheCommandAndTheStoresNote() async throws {
        let root = try await Self.builtNestedFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let affected = try await engine.affected(options: AffectedOptions(), freshness: freshness)

        #expect(affected.contains("  swift test --package-path Kit --filter "), "\(affected)")
        #expect(!affected.contains("  swift test --filter"), "\(affected)")
        #expect(affected.contains("index store via Kit/.build"), "\(affected)")

        // `where` names its store only in a `stores:` note, which an answer carries when there is something to say of its stores: here, a setting passed over.
        try TestSources.write("{\"indexStorePath\": \"nowhere\"}\n", to: "buildServer.json", in: root)
        let passingOver = try SiftEngine(directory: root)
        try await passingOver.awaitSemanticStore()
        let located = try await passingOver.lookup(symbol: "Widget", freshness: passingOver.ensureFresh())

        #expect(located.contains("stores: index store via Kit/.build; passed over: indexStorePath 'nowhere' in buildServer.json"), "\(located)")
    }

    @Test
    func aRootStoresTestCommandAndLabelAreUnchanged() {
        #expect(DiscoveredStore.swiftPMTestCommand(package: "") == "swift test")
        #expect(DiscoveredStore.swiftPMTestCommand(package: "Kit") == "swift test --package-path Kit")
        #expect(DiscoveredStore.label(provenance: .swiftPMBuild, package: "") == ".build")
    }

    private func refusal(_ rebuild: SemanticRefusal.Rebuild) -> SemanticRefusal {
        SemanticRefusal(path: "a.swift", reason: .modifiedSinceBuild, symbol: "A", kind: .structKind, rebuild: rebuild)
    }
}
