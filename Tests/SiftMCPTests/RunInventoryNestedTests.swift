//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers the inventory line and the bundle count for a repository that holds a nested package: what a root run leaves out, what a run naming the nested package declares, and how the package's directory is read.
@Suite(.temporaryDirectories)
struct RunInventoryNestedTests {
    /// A root run counts the root package's tests alone: the nested package's test target is another package's, which a root run never runs, so it is not reported as outside the run's scope.
    @Test
    func aRootRunDoesNotCountANestedPackagesTestsOutsideItsScope() async throws {
        let repository = try await Self.indexedRepository()
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedRoot, exiting: 0)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 3 declared, 3 reported"])
    }

    /// A root target the root manifest declares, by a `path:` that sits under a nested package's directory, stays the root's: the nested manifest never takes its tests out of the counts.
    @Test
    func aRootTargetDeclaredUnderANestedPackageIsStillCounted() async throws {
        let repository = try await Self.umbrellaRepository()
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedRoot + Self.ended(module: "AppTests", type: "DepotStoreTests", ["testOne"]), exiting: 0)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 4 declared, 4 reported"])
    }

    /// A root test target declared with a `path:` whose directory is neither the target's name nor under `Tests`, such as `Checks`, owns the tests inside it: only the declared path can attribute them.
    @Test
    func aRootTargetDeclaredByAnUnrelatedPathOwnsTheTestsInIt() async throws {
        let repository = try await Self.declaredPathRepository()
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedRoot, exiting: 0)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 3 declared, 3 reported"])
    }

    /// A run naming a nested package declares that package's bundles, as a root run declares the root's.
    @Test
    func aRunNamingANestedPackageDeclaresThatPackagesBundles() throws {
        let repository = try Self.repository()
        let rootRun = RunTestBundles.declared(forRunOf: ["swift", "test"], in: repository)

        #expect(rootRun == .declaredByManifest(1))
        for arguments in [["--package-path", "Sub"], ["--package-path=Sub"], ["-C", "Sub"], ["--chdir", "Sub"]] {
            #expect(
                RunTestBundles.declared(forRunOf: ["swift", "test"] + arguments, in: repository) == .declaredByManifest(2),
                "\(arguments.joined(separator: " ")) runs the nested package, which declares two test targets"
            )
        }
    }

    /// A package directory spelled through a shell variable prints the unchecked form of the line, so the reader knows the comparison did not happen.
    @Test(arguments: [["--package-path", "$PKG"], ["--package-path=$PKG"]])
    func aPackageDirectorySpelledThroughAVariableIsNamedAsNotChecked(arguments: [String]) async throws {
        let repository = try await Self.indexedRepository()
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedRoot, exiting: 0, extraArguments: arguments)

        #expect(thrown == nil)
        let inventory = recorded.printed.split(separator: "\n").map(String.init).filter { $0.hasPrefix("inventory:") }
        #expect(inventory.count == 1)
        #expect(inventory.first?.hasPrefix("inventory: not checked — ") == true)
    }

    /// With both `--package-path` and `-C` given, the package path names the package, in whichever order they are written.
    @Test(arguments: [false, true])
    func thePackagePathWinsOverAChdirInEitherOrder(packagePathFirst: Bool) async throws {
        let repository = try await Self.indexedRepository()
        let nested = repository.appendingPathComponent("Sub").path
        let package = ["--package-path", nested]
        let chdir = ["-C", repository.path]
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: Self.endedNested, exiting: 0, extraArguments: packagePathFirst ? package + chdir : chdir + package)

        #expect(thrown == nil)
        Self.expectInventory(recorded.printed, ["inventory: 2 declared, 2 reported"])
    }
}

private extension RunInventoryNestedTests {
    /// The root package's three tests, each started and passed, closed by the runner's count.
    static var endedRoot: [String] {
        ended(module: "GizmoTests", type: "PalletTests", ["testOne", "testTwo", "testThree"])
    }

    /// The nested package's two tests, each started and passed, closed by the runner's count.
    static var endedNested: [String] {
        ended(module: "WidgetTests", type: "DepotStoreTests", ["testOne", "testTwo"])
    }

    static func ended(module: String, type: String, _ methods: [String]) -> [String] {
        methods.flatMap {
            ["Test Case '-[\(module).\(type) \($0)]' started.", "Test Case '-[\(module).\(type) \($0)]' passed (0.100 seconds)."]
        } + ["Executed \(methods.count) tests, with 0 failures (0 unexpected) in 0.200 (0.204) seconds"]
    }

    /// Expects the answer's inventory lines to be exactly `expected`.
    static func expectInventory(_ printed: String, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let inventory = printed.split(separator: "\n").map(String.init).filter { $0.hasPrefix("inventory:") }
        #expect(inventory == expected, sourceLocation: sourceLocation)
    }

    /// A root package with one test target and a nested package `Sub` with two, manifests only.
    static func repository() throws -> URL {
        let root = try TemporaryDirectory.make("run-inventory-nested").resolvingSymlinksInPath()
        try write(manifest: "gizmo", testTargets: ["GizmoTests"], in: root)
        try write(manifest: "widget", testTargets: ["WidgetTests", "LegacyWidgetTests"], in: root.appendingPathComponent("Sub"))
        return root
    }

    /// The same repository with its sources written, committed and indexed: three root tests and two nested ones.
    static func indexedRepository(sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try repository()
        try write(RunInventoryNoteTests.threeMethodSource, to: root.appendingPathComponent("Tests/GizmoTests/PalletTests.swift"))
        try write("""
        import XCTest

        final class DepotStoreTests: XCTestCase {
            func testOne() {}
            func testTwo() {}
        }
        """, to: root.appendingPathComponent("Sub/Tests/WidgetTests/DepotStoreTests.swift"))
        try commit(root, sourceLocation: sourceLocation)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A root package declaring `GizmoTests` by an explicit path inside `Modules/Depot`, which holds an umbrella manifest of its own, and `AppTests` by the default path: three tests in the first, one in the second, committed and indexed.
    static func umbrellaRepository(sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TemporaryDirectory.make("run-inventory-umbrella").resolvingSymlinksInPath()
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "gizmo",
            targets: [
                .target(name: "GizmoCore"),
                .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"], path: "Modules/Depot/Tests/GizmoTests"),
                .testTarget(name: "AppTests", dependencies: ["GizmoCore"]),
            ]
        )
        """, to: root.appendingPathComponent("Package.swift"))
        try write(manifest: "depot", testTargets: ["GizmoTests"], in: root.appendingPathComponent("Modules/Depot"))
        try write(RunInventoryNoteTests.threeMethodSource, to: root.appendingPathComponent("Modules/Depot/Tests/GizmoTests/PalletTests.swift"))
        try write("""
        import XCTest

        final class DepotStoreTests: XCTestCase {
            func testOne() {}
        }
        """, to: root.appendingPathComponent("Tests/AppTests/DepotStoreTests.swift"))
        try commit(root, sourceLocation: sourceLocation)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A root package declaring `GizmoTests` by `path: "Checks"` alone, with its three tests in that directory, committed and indexed.
    static func declaredPathRepository(sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TemporaryDirectory.make("run-inventory-declared-path").resolvingSymlinksInPath()
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "gizmo",
            targets: [
                .target(name: "GizmoCore"),
                .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"], path: "Checks"),
            ]
        )
        """, to: root.appendingPathComponent("Package.swift"))
        try write(RunInventoryNoteTests.threeMethodSource, to: root.appendingPathComponent("Checks/PalletTests.swift"))
        try commit(root, sourceLocation: sourceLocation)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    static func write(manifest name: String, testTargets: [String], in directory: URL) throws {
        let core = name.capitalized + "Core"
        let tests = testTargets.map { "        .testTarget(name: \"\($0)\", dependencies: [\"\(core)\"])," }.joined(separator: "\n")
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [
                .target(name: "\(core)"),
        \(tests)
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
