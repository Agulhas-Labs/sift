//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the shape of an `affected` answer past the list cap: a target half reached or more is collapsed to two lines on every path, no selection is printed twice, and the limits block is two lines.
///
/// No build: the name-match fallback reaches these tests, which is all the shape needs.
@Suite(.temporaryDirectories)
struct AffectedCollapseOnceTests {
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
        return "import Testing\n@testable import Lib\n\nstruct \(name) {\n\(tests)\n}\n"
    }

    private static func affected(libTests: [String: String], gadgetTests: [String: String] = [:]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        for (target, files) in [("LibTests", libTests), ("GadgetTests", gadgetTests)] {
            for (name, source) in files {
                try TestSources.write(source, to: "Tests/\(target)/\(name).swift", in: root)
            }
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// A target past the cap with half its tests or more reached, but not all, is two lines and the target's command, not a list of suites.
    @Test
    func aTargetHalfReachedOrMoreIsTwoLinesWithTheTargetCommand() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(libTests: [
            "AlphaTests": Self.suite("AlphaTests", tests: count),
            "Orchard": Self.suite("Orchard", tests: 10, touching: false),
        ])

        #expect(output.contains("  LibTests: could not narrow below the target — \(count) of its \(count + 10) tests are reached, \(count) of them by name match\n"))
        #expect(output.contains("    run the target rather than a list: swift test --filter '^LibTests\\.' — xcodebuild test -only-testing:LibTests"))
        #expect(!output.contains("to run just these"))
        #expect(!output.contains("affected suites"))
    }

    /// The selection is printed once: the collapsed target's filter and argument appear in its two lines and in no later section.
    @Test
    func aCollapsedTargetIsNotRepeatedInTheSectionsBelow() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(
            libTests: [
                "AlphaTests": Self.suite("AlphaTests", tests: count),
                "Orchard": Self.suite("Orchard", tests: 10, touching: false),
            ],
            gadgetTests: ["GizmoTests": Self.suite("GizmoTests", tests: 2)]
        )

        #expect(Self.occurrences(of: "--filter '^LibTests\\.'", in: output) == 1)
        #expect(Self.occurrences(of: "-only-testing:LibTests", in: output) == 1)
        // The listed target is still selected below, once each.
        #expect(Self.occurrences(of: #"--filter '^GadgetTests\.GizmoTests/uses0\(\)'"#, in: output) == 1)
        #expect(Self.occurrences(of: "-only-testing:GadgetTests/GizmoTests/uses0()", in: output) == 1)
    }

    /// With nothing listed there is nothing for the runner sections to select, so they are not printed.
    @Test
    func anAnswerWithNoListedTargetHasNoRunnerSections() async throws {
        let count = AffectedRenderer.testListCap + 5
        let output = try await Self.affected(libTests: [
            "AlphaTests": Self.suite("AlphaTests", tests: count),
            "Orchard": Self.suite("Orchard", tests: 10, touching: false),
        ])

        #expect(!output.contains("xcodebuild — one argument per selection"))
        #expect(!output.contains("swift test — SwiftPM matches"))
    }

    /// The limits block is two lines, and the standing list is in the help topic.
    ///
    /// The first says what answered and that it is a lower bound; the second carries the entries specific to this answer.
    @Test
    func theLimitsBlockIsTwoLinesAndTheStandingListIsInTheHelpTopic() async throws {
        let output = try await Self.affected(libTests: ["AlphaTests": Self.suite("AlphaTests", tests: 2)])

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let heading = try #require(lines.firstIndex { $0.hasPrefix(AffectedBlindSpots.heading) })
        #expect(lines[heading].contains("a lower bound"))
        #expect(lines[heading + 1].hasPrefix(AffectedRenderer.limitBullet + "the reference walk stops at 2 hops"))
        #expect(!lines[heading + 2].hasPrefix(AffectedRenderer.limitBullet))
        #expect(!output.contains("macro-generated code is invisible to the parser"))

        let topic = try #require(HelpTopics.all.first { $0.name == "affected-limits" })
        for limit in AffectedBlindSpots.permanent {
            #expect(topic.body.contains(limit))
        }
        #expect(topic.body.contains(AffectedBlindSpots.moduleNameCaveat))
    }
}
