//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers the inventory line under a run of a package nested inside a repository: reconciled against that package's own manifest and tests, however the run names it.
@Suite(.temporaryDirectories)
struct NestedPackageInventoryTests {
    /// A run naming the nested package with a separate or an attached package-path value reconciles its two tests, not the outer package's three.
    @Test(arguments: [false, true])
    func aPackagePathRunOfANestedPackageCountsThatPackagesTests(attached: Bool) async throws {
        let repository = try await Self.indexedRepository()
        let nested = repository.appendingPathComponent(Self.nestedDirectory).path
        let flag = attached ? ["--package-path=\(nested)"] : ["--package-path", nested]
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedNested, exiting: 0, extraArguments: flag)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 2 declared, 2 reported"])
    }

    /// A run started in the nested package's own directory, naming no package, reconciles that package's two tests against the index of the repository holding it.
    @Test
    func aRunFromInsideANestedPackageCountsThatPackagesTests() async throws {
        let repository = try await Self.indexedRepository()
        let nested = repository.appendingPathComponent(Self.nestedDirectory)
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: nested, printing: Self.endedNested, exiting: 0)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 2 declared, 2 reported"])
    }

    /// A nested run that lost one of its package's tests names it, so the count is the nested package's and not a silence.
    @Test
    func aNestedRunThatLostATestNamesIt() async throws {
        let repository = try await Self.indexedRepository()
        let nested = repository.appendingPathComponent(Self.nestedDirectory).path
        let lines = Self.ended(["testOne"])
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: lines, exiting: 0, extraArguments: ["--package-path", nested])

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 2 declared, 1 reported — 1 never reported: WidgetTests/DepotStoreTests/testTwo()"])
    }
}

private extension NestedPackageInventoryTests {
    /// Where the nested package sits, relative to the repository root.
    static var nestedDirectory: String {
        "Tools/Widget"
    }

    /// The nested package's test source: one case declaring two ordinary methods.
    static var nestedSource: String {
        """
        import XCTest

        final class DepotStoreTests: XCTestCase {
            func testOne() {}
            func testTwo() {}
        }
        """
    }

    /// Both of the nested package's tests started and passed, closed by the runner's own count.
    static var endedNested: [String] {
        ended(["testOne", "testTwo"])
    }

    /// Each named method started and passed, closed by the runner's count of them.
    static func ended(_ methods: [String]) -> [String] {
        methods.flatMap {
            ["Test Case '-[WidgetTests.DepotStoreTests \($0)]' started.", "Test Case '-[WidgetTests.DepotStoreTests \($0)]' passed (0.100 seconds)."]
        } + ["Executed \(methods.count) tests, with 0 failures (0 unexpected) in 0.200 (0.204) seconds"]
    }

    /// Expects the answer's inventory lines to be exactly `expected`.
    static func expectInventory(_ printed: String, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let inventory = printed.split(separator: "\n").map(String.init).filter { $0.hasPrefix("inventory:") }
        #expect(inventory == expected, sourceLocation: sourceLocation)
    }

    /// A committed repository whose root package declares three tests and whose nested package declares two, with its index built.
    static func indexedRepository(sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TemporaryDirectory.make("nested-package-inventory").resolvingSymlinksInPath()
        try write(manifest: "gizmo", testTarget: "GizmoTests", in: root)
        try write(RunInventoryNoteTests.threeMethodSource, to: root.appendingPathComponent("Tests/GizmoTests/PalletTests.swift"))
        let nested = root.appendingPathComponent(nestedDirectory)
        try write(manifest: "widget", testTarget: "WidgetTests", in: nested)
        try write(nestedSource, to: nested.appendingPathComponent("Tests/WidgetTests/DepotStoreTests.swift"))
        try commit(root, sourceLocation: sourceLocation)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Writes a manifest declaring one library target and one test target into `directory`.
    static func write(manifest name: String, testTarget: String, in directory: URL) throws {
        let core = name.capitalized + "Core"
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [
                .target(name: "\(core)"),
                .testTarget(name: "\(testTarget)", dependencies: ["\(core)"]),
            ]
        )
        """, to: directory.appendingPathComponent("Package.swift"))
    }

    static func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Makes `root` a repository and commits everything in it, with every inherited git variable stripped so the commands cannot reach another repository.
    static func commit(_ root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let steps = [["init", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@example.com", "-c", "user.name=Tester", "commit", "-m", "fixture"]]
        for (offset, arguments) in steps.enumerated() {
            if offset > 0 {
                try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "the fixture's repository was not made inside its own directory", sourceLocation: sourceLocation)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = root
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed in the fixture", sourceLocation: sourceLocation)
        }
    }
}
