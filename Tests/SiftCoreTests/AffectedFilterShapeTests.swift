//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the shape of the lines `affected` prints to run what it lists: the whole-target line is a command of its own, a suite's filter selects that suite and not a sibling whose name begins with it, and a target whose every test is affected is named whole however few rows it would have had.
///
/// No build: the name-match fallback reaches these tests, which is all the output's shape needs.
@Suite(.temporaryDirectories)
struct AffectedFilterShapeTests {
    private static func manifest() -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
                .testTarget(name: "GadgetTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    private static func suite(_ name: String, tests count: Int, touching: Bool = true) -> String {
        let body = touching ? "_ = Widget()" : ""
        let tests = (0 ..< count).map { "    @Test func uses\($0)() { \(body) }" }.joined(separator: "\n")
        return "struct \(name) {\n\(tests)\n}\n"
    }

    private static func affected(libTests: [String: String], gadgetTests: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        for (target, files) in [("LibTests", libTests), ("GadgetTests", gadgetTests)] {
            for (name, source) in files {
                try TestSources.write("import Testing\n@testable import Lib\n\n" + source, to: "Tests/\(target)/\(name).swift", in: root)
            }
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// The whole-target line names both runners by the command that starts them, the way the per-suite lines do.
    @Test
    func theWholeTargetLineIsRunnableForEachRunner() async throws {
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: 14), "BetaTests": Self.suite("BetaTests", tests: 14)],
            gadgetTests: ["Orchard": Self.suite("Orchard", tests: 1, touching: false)]
        )

        #expect(output.contains("  LibTests: all 28 tests — swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests"))
    }

    /// A suite whose name begins another suite's is printed with a filter that selects only itself: as a regex over the ids it matches the suite's own tests and not the sibling's.
    @Test
    func aSuiteFilterDoesNotSelectASiblingWhoseNameBeginsWithIt() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(
            libTests: [:],
            gadgetTests: [
                "Gizmo": Self.suite("Gizmo", tests: count),
                "GizmoTests": Self.suite("GizmoTests", tests: count, touching: false),
                "Orchard": Self.suite("Orchard", tests: count, touching: false),
            ]
        )

        let filters = output.matches(of: /--filter '([^']*)'/).map { String($0.output.1) }
        let filter = try #require(filters.first { $0.hasPrefix(#"^GadgetTests\.Gizmo"#) }, "no suite filter in:\n\(output)")

        #expect(filter == #"^GadgetTests\.Gizmo(/|$)"#)
        #expect("GadgetTests.Gizmo/uses0()".range(of: filter, options: .regularExpression) != nil)
        #expect("GadgetTests.GizmoTests/uses0()".range(of: filter, options: .regularExpression) == nil)
    }

    /// Every suite of the target is affected and its rows fit under the cap: the heading still carries the whole-target line, so the target can be run by one command.
    @Test
    func aFullyAffectedTargetUnderTheCapStillCarriesTheWholeTargetLine() async throws {
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: 3), "BetaTests": Self.suite("BetaTests", tests: 3)],
            gadgetTests: ["Orchard": Self.suite("Orchard", tests: 1, touching: false)]
        )

        #expect(output.contains("  LibTests — 6 tests\n    LibTests: all 6 tests — swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests\n"))
    }

    /// The whole-target line's filter selects exactly that target: as a regex over the ids it matches the target's tests and not those of a target whose name begins with it.
    @Test
    func theWholeTargetFilterDoesNotSelectATargetWhoseNameBeginsWithIt() async throws {
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: 14), "BetaTests": Self.suite("BetaTests", tests: 14)],
            gadgetTests: [:]
        )

        let line = try #require(output.split(separator: "\n").first { $0.contains("LibTests: all 28 tests") }, "no whole-target line in:\n\(output)")
        let filter = try #require(line.firstMatch(of: /--filter '([^']*)'/).map { String($0.output.1) })

        #expect(filter == #"^LibTests\."#)
        #expect("LibTests.AlphaTests/uses0()".range(of: filter, options: .regularExpression) != nil)
        #expect("LibTestsExtra.AlphaTests/uses0()".range(of: filter, options: .regularExpression) == nil)
    }

    /// The collapse line is a command of its own, in the shape of the whole-target line, and its filter selects exactly the target.
    @Test
    func theCollapseLineIsRunnableAndItsFilterIsAnchoredToTheTarget() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(
            libTests: ["AlphaTests": Self.suite("AlphaTests", tests: count), "BetaTests": Self.suite("BetaTests", tests: 10, touching: false)],
            gadgetTests: [:]
        )

        #expect(output.contains(#"    run the target rather than a list: swift test --filter '^LibTests\.' — xcodebuild test -only-testing:LibTests"#))
    }

    /// A single test's filter ends where the test's id does, so it does not also select a test whose name begins with it.
    @Test
    func aTestFilterDoesNotSelectATestWhoseNameBeginsWithIt() {
        let two = TestSymbol(target: "LibTests", suite: "WidgetTests", function: "testTwo", style: .xcTest)
        let filter = two.anchoredSwiftTestFilter

        #expect(filter == #"^LibTests\.WidgetTests/testTwo$"#)
        #expect("LibTests.WidgetTests/testTwo".range(of: filter, options: .regularExpression) != nil)
        #expect("LibTests.WidgetTests/testTwoAndHalf".range(of: filter, options: .regularExpression) == nil)
    }

    /// A suite's or test's filter opens at the start of the id, so a target whose name ends with this one's, holding a suite of the same name, is not also selected.
    @Test
    func aFilterDoesNotSelectATargetWhoseNameEndsWithTheTargetsName() {
        let suite = TestSymbol(target: "LibTests", suite: "GadgetTests", function: nil, style: .xcTest)
        let function = TestSymbol(target: "LibTests", suite: "GadgetTests", function: "testTwo", style: .xcTest)
        let swiftTesting = TestSymbol(target: "LibTests", suite: "GadgetTests", function: "testTwo()", style: .swiftTesting)

        for (symbol, id) in [(suite, "GadgetTests/testTwo"), (function, "GadgetTests/testTwo"), (swiftTesting, "GadgetTests/testTwo()")] {
            let filter = symbol.anchoredSwiftTestFilter
            #expect("LibTests.\(id)".range(of: filter, options: .regularExpression) != nil)
            #expect("UILibTests.\(id)".range(of: filter, options: .regularExpression) == nil)
            #expect("XLibTests.\(id)".range(of: filter, options: .regularExpression) == nil)
        }
    }
}
