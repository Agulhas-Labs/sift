//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A root package's store resolves a declaration through its own file's exact path, so a dependency's file that ends in the same path and declares the same name on the same line is not taken for it.
@Suite(.serialized, .temporaryDirectories)
struct RootStoreExactPathTests {
    /// A root package with two path dependencies, one sorting before it and one after, each declaring `helper(x:)` on line 1 of a file at `Sources/Lib/Shared.swift`; the last commit changes the root's signature, and the root calls its own three times and each dependency's once.
    private static func builtFixture() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Root",
                dependencies: [.package(path: "ADep"), .package(path: "ZDep")],
                targets: [.target(name: "RootLib", dependencies: [.product(name: "DepLib", package: "ADep"), .product(name: "DepTwo", package: "ZDep")], path: "Sources/Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Dep", products: [.library(name: "DepLib", targets: ["DepLib"])], targets: [.target(name: "DepLib", path: "Sources/Lib")])
            """,
            to: "ADep/Package.swift",
            in: root
        )
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "ZDep", products: [.library(name: "DepTwo", targets: ["DepTwo"])], targets: [.target(name: "DepTwo", path: "Sources/Lib")])
            """,
            to: "ZDep/Package.swift",
            in: root
        )
        try TestSources.write("public func helper(x: Int) -> Int { x }\n", to: "ADep/Sources/Lib/Shared.swift", in: root)
        try TestSources.write("public func helper(x: Int) -> Int { x }\n", to: "ZDep/Sources/Lib/Shared.swift", in: root)
        try TestSources.write("public func helper(x: Int) -> Int { x }\n", to: "Sources/Lib/Shared.swift", in: root)
        try TestSources.write("import DepLib\nimport DepTwo\n\npublic func use() {\n    _ = RootLib.helper(x: 1)\n    _ = RootLib.helper(x: 1)\n    _ = RootLib.helper(x: 1)\n    _ = DepLib.helper(x: 2)\n    _ = DepTwo.helper(x: 3)\n}\n", to: "Sources/Lib/Use.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public func helper(x: Int) -> Int? { x }\n", to: "Sources/Lib/Shared.swift", in: root)
        try TestSources.commitAll(in: root, message: "root shared grows")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }

    @Test
    func aDependencyFileWithTheSameTrailingPathIsNotTakenForTheRootsDeclaration() async throws {
        let root = try await Self.builtFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let answer = try await engine.diff(
            options: DiffOptions(range: DiffRange.resolve("HEAD~1..HEAD", git: GitContext(repoRoot: root))),
            freshness: engine.ensureFresh()
        )

        #expect(answer.contains("helper(x:) — resolved by the index store: 3 call sites"), "\(answer)")
        #expect(["5", "6", "7"].allSatisfy { answer.contains("Sources/Lib/Use.swift:\($0)") }, "\(answer)")
        #expect(!answer.contains("Sources/Lib/Use.swift:8") && !answer.contains("Sources/Lib/Use.swift:9"), "\(answer)")
    }
}
