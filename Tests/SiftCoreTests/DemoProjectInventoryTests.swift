//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Reads the inventory of the committed demo project, which is the measured ground truth the test-running features are validated against.
///
/// The demo is indexed here as its own repository — its `project.yml` is what attributes the targets, spaces and all — so the assertions below are about the real files rather than about a fixture written to agree with them.
@Suite(.temporaryDirectories)
struct DemoProjectInventoryTests {
    private static let demoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ValidationProjects/TestDemo")

    private static func inventory(sourceLocation: SourceLocation = #_sourceLocation) throws -> TestInventory {
        let store = try TestSources.makeStore()
        let resolver = ModuleResolver(repoRoot: demoRoot, config: SiftConfig())
        let parsed = try swiftFiles().compactMap { path -> ParsedFile? in
            FileParser.parse(absoluteURL: demoRoot.appendingPathComponent(path), repoRelativePath: path)
        }
        #expect(parsed.isEmpty == false, sourceLocation: sourceLocation)
        try store.replaceFiles(parsed) { path in
            (resolver.module(for: path), resolver.resolvedModule(for: path) == nil)
        }
        return try TestInventory.read(store: store, repositoryRoot: demoRoot)
    }

    /// Every Swift file in the demo, repo-relative to it.
    private static func swiftFiles() throws -> [String] {
        let contents = try FileManager.default.subpathsOfDirectory(atPath: demoRoot.path)
        return contents.filter { $0.hasSuffix(".swift") }.sorted()
    }

    private static func test(_ function: String, in inventory: TestInventory, sourceLocation: SourceLocation = #_sourceLocation) throws -> DeclaredTest {
        try #require(inventory.tests.first { $0.function == function }, sourceLocation: sourceLocation)
    }

    /// The parameterised test is one declared test, whatever it is given to run with — the unit every tally uses.
    @Test
    func theSwiftTestingSuiteIsCountedPerFunctionWithItsDisabledTestNamedAsOne() throws {
        let inventory = try Self.inventory()
        let math = inventory.tests.filter { $0.suite == "MathSuite" }

        #expect(math.map(\.function) == [
            "addsTwoNumbers()",
            "doublingIsEven(_:)",
            "multipliesLargeNumbers()",
            "subtractsTwoNumbers()",
        ])
        #expect(math.allSatisfy { $0.target == "DemoUnitTests" && $0.style == .swiftTesting })
        #expect(try Self.test("multipliesLargeNumbers()", in: inventory).disposition == .disabled(reason: "not ready"))
        #expect(try Self.test("doublingIsEven(_:)", in: inventory).disposition == .runs)
        // `@Suite("Math")` names the suite; no test in it wrote a display name of its own.
        #expect(math.allSatisfy { $0.displayName == nil })
    }

    /// The XCTest dispositions the demo really carries: a body that throws `XCTSkip` first, and one that reaches `XCTFail` only after a guard.
    @Test
    func theXCTestBodiesAreReadByTheirFirstStatementAlone() throws {
        let inventory = try Self.inventory()

        #expect(try Self.test("testSkipsWhenUnsupported()", in: inventory).disposition == .skips(reason: "not supported on this configuration"))
        #expect(try Self.test("testAddition()", in: inventory).disposition == .runs)
        // `testFailsOnce` calls `XCTFail` inside a guard, several statements in: that is a test that fails, not one switched off.
        #expect(try Self.test("testFailsOnce()", in: inventory).disposition == .runs)
        #expect(try Self.test("testAddition()", in: inventory).suite == "CalculatorTests")
        #expect(try Self.test("testAddition()", in: inventory).style == .xcTest)
    }

    /// A target whose name a Swift identifier cannot spell keeps its spaces, which is the spelling a plan and an enumeration both use.
    @Test
    func aTargetSpelledWithSpacesIsInventoriedWithThem() throws {
        let inventory = try Self.inventory()
        let spaced = inventory.tests.filter { $0.suite == "SpacedTests" }

        #expect(spaced.map(\.function) == ["testCountsDown()", "testCountsUp()"])
        #expect(spaced.allSatisfy { $0.target == "Demo Spaced Tests" })
        #expect(spaced.allSatisfy { $0.targetWasGuessed == false })
        #expect(inventory.guessedTargets.isEmpty)
    }
}
