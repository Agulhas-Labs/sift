//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which runners `affected` prints commands for, decided by the index store's provenance, and the target's own filter that stands in for a suite list past 2,000 characters.
///
/// The test sections are rendered directly from a reached set and an inventory, so a store's provenance can be stated without building one.
@Suite(.temporaryDirectories)
struct AffectedRunnerChoiceTests {
    private static func declared(_ suite: String, tests count: Int) -> [DeclaredTest] {
        (0 ..< count).map {
            DeclaredTest(
                target: "LibTests",
                targetWasGuessed: false,
                suite: suite,
                function: "t\($0)()",
                style: .swiftTesting,
                displayName: nil,
                disposition: .runs,
                path: "Tests/LibTests/\(suite).swift",
                line: $0 + 1
            )
        }
    }

    /// A partly affected target of `suites` affected suites of two tests each, beside an unreached suite of `idle` tests.
    private static func sections(
        suites: Int,
        idle: Int,
        provenance: DiscoveredStore.Provenance?,
        package: String = "",
        listSuites: Bool = false,
        outsideAnySuite: Bool = false
    ) throws -> String {
        let names = (0 ..< suites).map { "Alpha\($0)" }
        let loose = outsideAnySuite ? [DeclaredTest(target: "LibTests", targetWasGuessed: false, suite: "", function: "loose()", style: .swiftTesting, displayName: nil, disposition: .runs, path: "Tests/LibTests/Loose.swift", line: 1)] : []
        let inventory = TestInventory(tests: names.flatMap { declared($0, tests: 2) } + declared("Orchard", tests: idle) + loose, guessedTargets: [])
        var reached: [TestSymbol: AffectedRenderer.Evidence] = [:]
        for name in names {
            reached[TestSymbol(target: "LibTests", suite: name, function: nil, style: .swiftTesting)] = AffectedRenderer.Evidence(
                depth: 1,
                resolved: true,
                state: .live,
                path: "Tests/LibTests/\(name).swift",
                line: 1
            )
        }
        if outsideAnySuite {
            reached[TestSymbol(target: "LibTests", suite: nil, function: "loose()", style: .swiftTesting)] = AffectedRenderer.Evidence(depth: 1, resolved: true, state: .live, path: "Tests/LibTests/Loose.swift", line: 1)
        }
        return AffectedTestSections(
            reached: reached,
            inventory: inventory,
            options: AffectedOptions(listSuites: listSuites),
            ways: 6,
            package: package,
            runners: AffectedRunners(provenance: provenance, package: package),
            provenance: provenance
        ).lines().joined(separator: "\n")
    }

    @Test
    func aSwiftPMStorePrintsSwiftTestCommandsOnly() throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: .swiftPMBuild)

        #expect(output.contains("affected tests (60 in 1 target) — swift test commands only (the index store is .build):"))
        #expect(output.contains("    to run just these 30 suites: swift test --filter"))
        #expect(!output.contains("xcodebuild"))
        #expect(!output.contains("-only-testing"))
    }

    @Test
    func aDerivedDataStorePrintsXcodebuildCommandsOnly() throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: .derivedData)

        #expect(output.contains("— xcodebuild commands only (the index store is DerivedData):"))
        #expect(output.contains("    to run just these 30 suites: xcodebuild test -only-testing:"))
        #expect(!output.contains("swift test"))
        #expect(!output.contains("--filter"))
    }

    @Test
    func aBuildServerStorePrintsXcodebuildCommandsOnly() throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: .buildServerJSON)

        #expect(output.contains("xcodebuild commands only (the index store is buildServer.json)"))
        #expect(!output.contains("swift test"))
    }

    @Test(arguments: [DiscoveredStore.Provenance.config, .inTree("build/dd"), nil])
    func otherStoresAndNoneKeepBothRunners(provenance: DiscoveredStore.Provenance?) throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: provenance)

        #expect(output.contains("affected tests (60 in 1 target):"))
        #expect(output.contains("    to run just these 30 suites: swift test --filter"))
        #expect(output.contains("    to run just these 30 suites: xcodebuild test -only-testing:"))
        #expect(!output.contains("commands only"))
    }

    @Test
    func aSuiteListPast2000CharactersBecomesTheTargetsOwnFilter() throws {
        let output = try Self.sections(suites: 130, idle: 400, provenance: .swiftPMBuild)

        #expect(output.contains("    260 tests affected — the commands below run the whole target"))
        #expect(output.contains("    to run them, run the target: swift test --filter '\(TestSymbol.anchoredTargetFilter("LibTests"))' — all 660 of its tests, 400 beyond the 260 affected"))
        #expect(output.contains("    --suites lists the 130 suites one by one"))
        #expect(!output.contains("to run just these"))
        #expect(!output.contains("Alpha1"))
    }

    @Test
    func theXcodebuildListPast2000CharactersBecomesTheTargetsOwnArgument() throws {
        let output = try Self.sections(suites: 130, idle: 400, provenance: .derivedData)

        #expect(output.contains("to run them, run the target: xcodebuild test -only-testing:LibTests — all 660 of its tests, 400 beyond the 260 affected"))
        #expect(output.contains("    --suites lists the 130 suites one by one"))
        #expect(!output.contains("to run just these"))
    }

    @Test
    func suitesRestoresTheListAtAnyLength() throws {
        let output = try Self.sections(suites: 130, idle: 400, provenance: .swiftPMBuild, listSuites: true)

        #expect(output.contains("    260 tests affected — the commands below run exactly the affected suites"))
        #expect(output.contains("    to run just these 130 suites: swift test --filter"))
        #expect(output.contains("Alpha129"))
        #expect(!output.contains("run the target"))
        #expect(!output.contains("--suites lists"))
    }

    @Test
    func aListUnder2000CharactersIsUnchanged() throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: nil)

        #expect(output.contains("    60 tests affected — the commands below run exactly the affected suites"))
        #expect(!output.contains("run the target"))
        #expect(!output.contains("--suites lists"))
    }

    @Test
    func aNestedPackageSwiftPMStoreKeepsBothRunners() throws {
        let output = try Self.sections(suites: 30, idle: 100, provenance: .swiftPMBuild, package: "Packages/Core")

        #expect(output.contains("to run just these 30 suites: swift test --package-path Packages/Core --filter"))
        #expect(output.contains("    to run just these 30 suites: xcodebuild test -only-testing:"))
        #expect(!output.contains("commands only"))
    }

    @Test
    func whenOnlyTheSwiftTestListIsReplacedTheIntroAndTheLeftOutLineSayWhichLineRunsWhat() throws {
        let output = try Self.sections(suites: 60, idle: 400, provenance: nil, outsideAnySuite: true)

        #expect(output.contains("to run them, run the target: swift test --filter"))
        #expect(output.contains("to run just these 60 suites: xcodebuild test -only-testing:"))
        #expect(output.contains("the xcodebuild line runs exactly the affected suites; the swift test line runs the whole target"))
        #expect(!output.contains("the commands below run"))
        #expect(output.contains("      left out of the xcodebuild line: 1 test declared outside any suite"))
    }
}
