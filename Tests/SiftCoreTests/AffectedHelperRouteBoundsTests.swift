//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two bounds on the route through a suite's helper: the walk-on ends at a test function and not at the helper, and a capped frontier gives a helper's name only the room the ordinary names leave.
@Suite(.serialized, .temporaryDirectories)
struct AffectedHelperRouteBoundsTests {
    private static func manifest() -> String {
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

    private static var widget: String {
        "public struct Widget {\n    public init() {}\n}\n"
    }

    private static var changedWidget: String {
        "public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n"
    }

    /// A suite whose helper `helper` has the body `body`, and a test of its own that calls it.
    private static func lampTests(helper: String, returning type: String, body: String) -> String {
        """
        import Testing
        @testable import Lib

        struct LampTests {
            static func \(helper)() -> \(type) {
                \(body)
            }

            @Test func lights() {
                _ = Self.\(helper)()
            }
        }
        """
    }

    private static func kettleTests(calling call: String) -> String {
        """
        import Testing
        @testable import Lib

        struct KettleTests {
            @Test func boils() {
                _ = \(call)
            }
        }
        """
    }

    /// The `affected` answer for a repository whose `Widget` change is uncommitted, built over when `built` is set.
    private static func answer(files: [String: String], built: Bool, options: AffectedOptions = AffectedOptions()) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write(widget, to: "Sources/Lib/Core.swift", in: root)
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(changedWidget, to: "Sources/Lib/Core.swift", in: root)
        if built {
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: options, freshness: freshness)
    }

    /// The suite's helper is three hops from `Widget`, and a test calling it four: the helper is a route and not a test, so the walk-on records its suite there and goes on to the test that calls it.
    @Test
    func theWalkOnGoesPastASuitesHelperToTheTestThatCallsIt() async throws {
        let output = try await Self.answer(
            files: [
                "Sources/Lib/Chain.swift": "func forge() -> String {\n    _ = Widget()\n    return \"forged\"\n}\n\nfunc temper() -> String {\n    forge()\n}\n",
                "Tests/LibTests/LampTests.swift": Self.lampTests(helper: "rig", returning: "String", body: "temper()"),
                "Tests/LibTests/KettleTests.swift": Self.kettleTests(calling: "LampTests.rig()"),
            ],
            built: true
        )

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("LibTests.LampTests — 3 hops — "))
        #expect(output.contains("LibTests.KettleTests/boils() — 4 hops — "))
        #expect(output.contains("Sources/Lib/Core.swift at 4 hops"))
    }

    /// 201 names reach the next hop: a suite's helper `depot`, which sorts first, and 200 ordinary functions.
    ///
    /// The cut keeps the 200 ordinary ones, so the test calling the last of them is still found, and the cap is named.
    @Test
    func aCappedFrontierKeepsEveryOrdinaryNameBeforeAHelperName() async throws {
        let functions = (0 ..< 200).map { index in
            let name = "orchard" + String(format: "%03d", index)
            return "func \(name)() -> Widget {\n    Widget()\n}\n"
        }.joined(separator: "\n")
        let output = try await Self.answer(
            files: [
                "Sources/Lib/Many.swift": functions,
                "Tests/LibTests/LampTests.swift": Self.lampTests(helper: "depot", returning: "Widget", body: "Widget()"),
                "Tests/LibTests/KettleTests.swift": Self.kettleTests(calling: "orchard199()"),
            ],
            built: false
        )

        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops, name match"))
        #expect(output.contains("note: the name-matched fallback carried only 200 names into the next hop"))
    }

    /// The cut on a later hop is the ordinary names' too: a name reached through a helper's sites at hop two is routed through the helpers' room at hop three, so it cannot displace an ordinary name.
    ///
    /// Without `aardvark`, 200 ordinary names reach hop three and `KettleTests` is found through `orchard199`. With it, the helper route `depot` then `aardvark` is one more name; it takes only the room the ordinary names leave, so `KettleTests` stays listed.
    @Test
    func aNameReachedThroughAHelperDoesNotDisplaceAnOrdinaryNameOnALaterHop() async throws {
        let functions = (0 ..< 200).map { index in
            "func orchard" + String(format: "%03d", index) + "() {\n    bridge()\n}\n"
        }.joined(separator: "\n") + "\nfunc bridge() -> Widget {\n    Widget()\n}\n"
        let output = try await Self.answer(
            files: [
                "Sources/Lib/Many.swift": functions,
                "Tests/LibTests/LampTests.swift": Self.lampTests(helper: "depot", returning: "Widget", body: "Widget()"),
                "Tests/LibTests/KettleTests.swift": Self.kettleTests(calling: "orchard199()"),
                "Tests/LibTests/Aardvark.swift": "func aardvark() {\n    LampTests.depot()\n}\n",
            ],
            built: false,
            options: AffectedOptions(depth: 3)
        )

        #expect(output.contains("LibTests.KettleTests/boils() — 3 hops"))
    }
}
