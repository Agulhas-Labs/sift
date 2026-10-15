//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` right after an edit, before a rebuild: the store refuses every changed file, and the answer is seeded from the declarations the diff touched and walked to their call sites, never from every declaration in those files.
@Suite(.serialized, .temporaryDirectories)
struct AffectedAfterEditTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
                .testTarget(name: "WideTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    /// A file declaring the method the rename touches beside declarations it leaves alone, a helper calling the method, a suite reaching it through the helper, a suite reaching only the untouched declarations, and a target past the list cap whose every test reaches the helper.
    private static func makeEditedRepo() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write(
            """
            public struct Valve {
                public init() {}
                public func gate(open: Bool) -> Bool { open }
                public func untouchedDial() -> Int { 1 }
            }

            public struct Bystander {
                public init() {}
                public func untouchedLamp() -> Int { 2 }
            }
            """,
            to: "Sources/Lib/Valve.swift",
            in: root
        )
        try TestSources.write("public func operateValve() -> Bool { Valve().gate(open: true) }\n", to: "Sources/Lib/Operator.swift", in: root)
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct ValveRouteTests {
                @Test func operatingOpensTheValve() { #expect(operateValve()) }
            }
            """,
            to: "Tests/LibTests/ValveRouteTests.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct BystanderTests {
                @Test func dialReadsOne() { #expect(Valve().untouchedDial() == 1) }
                @Test func lampReadsTwo() { #expect(Bystander().untouchedLamp() == 2) }
                @Test func bystanderIsBuilt() { _ = Bystander() }
            }
            """,
            to: "Tests/LibTests/BystanderTests.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct WideTests {
            \((0 ... AffectedRenderer.testListCap).map { "    @Test func operation\($0)() { #expect(operateValve()) }" }.joined(separator: "\n"))
            }
            """,
            to: "Tests/WideTests/WideTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        // The rename, written after the build: the declaration and its one call site, as an edit leaves them.
        let valve = try String(contentsOf: root.appendingPathComponent("Sources/Lib/Valve.swift"), encoding: .utf8)
        try TestSources.write(valve.replacingOccurrences(of: "func gate(open", with: "func mainGate(open"), to: "Sources/Lib/Valve.swift", in: root)
        try TestSources.write("public func operateValve() -> Bool { Valve().mainGate(open: true) }\n", to: "Sources/Lib/Operator.swift", in: root)
        return root
    }

    private static func affected(_ root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// One fixture for the three rules, since each needs a build: the seeds are the touched declarations, the walk follows their call sites, and a target the walk could not narrow is said to be one rather than listed.
    @Test
    func aRenameBeforeTheRebuildReachesItsCallersAndNotTheRestOfTheFile() async throws {
        let root = try await Self.makeEditedRepo()

        let output = try await Self.affected(root)

        #expect(output.contains("semantic REFUSED"))
        #expect(output.contains("after-edit walk — syntactic, lower bound: the 2 files changed since the build were seeded from the 3 names the diff touched there (gate, mainGate, operateValve)"))
        #expect(output.contains("LibTests.ValveRouteTests/operatingOpensTheValve() — 1 hop, name match"))
        // The untouched declarations of the changed file are no seed: a suite naming only them is not reached.
        #expect(!output.contains("BystanderTests"))
        // Every test of WideTests is reached by name match: the answer says it could not narrow, with why and the command, and lists none of them.
        #expect(output.contains("  WideTests: could not narrow below the target — 26 of its 26 tests are reached by name match from the 3 touched names (gate, mainGate, operateValve)"))
        #expect(output.contains("    run the target rather than a list: swift test --filter '^WideTests\\.'"))
        // The store is SwiftPM's own `.build`, so only the repository's runner is printed, and the heading says so.
        #expect(output.contains("commands only (the index store is .build)"))
        #expect(!output.contains("xcodebuild"))
        #expect(!output.contains("operation0()"))
        // The commands under the list select only the listed target, beside one named by its own command, and say so.
        #expect(output.contains("swift test — SwiftPM matches --filter as a regex against the printed test id (listed targets only; the targets above are named by their own command):"))
    }
}
