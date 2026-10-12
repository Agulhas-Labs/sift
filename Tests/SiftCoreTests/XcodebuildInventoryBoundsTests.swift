//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which `xcodebuild` test runs the declared-test inventory bounds as it bounds a plain `swift test`, which say they were not checked, and which say nothing.
@Suite(.temporaryDirectories)
struct XcodebuildInventoryBoundsTests {
    /// The line an unnarrowed `xcodebuild` test run that no manifest bounds carries.
    static var unboundedLine: String {
        "inventory: not checked — an xcodebuild scheme runs the test targets it names, which no package manifest bounds"
    }

    /// The run of a package's `-Package` scheme from its own directory is bounded by that package, and so carries no unchecked line.
    @Test
    func thePackageSchemeRunFromThePackageDirectoryIsBounded() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = Self.test(["-scheme", "Gizmo-Package", "-destination", "platform=macOS"])
        let report = Self.report(of: arguments, lines: Self.onePass)

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == package)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package) == nil)
    }

    /// A run narrowed to part of its scheme, in either spelling of the flag, runs a set no manifest bounds and says nothing about the inventory, as a filtered `swift test` does.
    @Test(arguments: [["-only-testing:GizmoTests/PalletTests"], ["-only-testing", "GizmoTests"], ["-skip-testing:GizmoTests"], ["-testPlan", "Smoke"]])
    func aNarrowedRunOfThePackageSchemeSaysNothing(narrowing: [String]) throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = Self.test(["-scheme", "Gizmo-Package"] + narrowing)
        let report = Self.report(of: arguments, lines: Self.onePass)

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package) == nil)
    }

    /// A run that names a project reads the project's scheme, not the manifest beside it, so it says it was not checked.
    @Test
    func aRunNamingAProjectSaysItWasNotChecked() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = Self.test(["-project", "Gizmo.xcodeproj", "-scheme", "Gizmo-Package"])

        try Self.expectUnbounded(arguments, in: package)
    }

    /// An Xcode project beside the manifest is what `xcodebuild` reads there, so the package's scheme name bounds nothing.
    @Test
    func aPackageDirectoryHoldingAProjectSaysItWasNotChecked() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Gizmo.xcodeproj"), withIntermediateDirectories: true)

        try Self.expectUnbounded(Self.test(["-scheme", "Gizmo-Package"]), in: package)
    }

    /// A product's own scheme runs the test targets it names rather than every one the manifest declares, so it says it was not checked.
    @Test
    func aProductSchemeSaysItWasNotChecked() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }

        try Self.expectUnbounded(Self.test(["-scheme", "Gizmo"]), in: package)
    }

    /// A scheme file the package keeps, shared or one user's, replaces the scheme Xcode generates and can skip any test target, so the run says it was not checked and names the file.
    @Test(arguments: [".swiftpm/xcode/xcshareddata/xcschemes", ".swiftpm/xcode/xcuserdata/clerk.xcuserdatad/xcschemes"])
    func aKeptPackageSchemeFileSaysItWasNotChecked(directory: String) throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let schemes = package.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        try "<Scheme/>\n".write(to: schemes.appendingPathComponent("Gizmo-Package.xcscheme"), atomically: true, encoding: .utf8)
        let arguments = Self.test(["-scheme", "Gizmo-Package"])
        let report = Self.report(of: arguments, lines: Self.onePass)

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package)?.lines == [
            "inventory: not checked — \(directory)/Gizmo-Package.xcscheme replaces the scheme Xcode generates over the package's test targets, so no package manifest bounds the tests it runs",
        ])
    }

    /// A build runs no test, so it carries no inventory line of either kind.
    @Test
    func aBuildSaysNothing() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = ["xcodebuild", "build", "-scheme", "Gizmo-Package"]
        let report = Self.report(of: arguments, lines: Self.onePass)

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package) == nil)
    }

    /// A `-quiet` run prints no line for a test that passed, so reconciling it would name every passing test as never reported; it says so instead, even with no test line in its log.
    @Test
    func aQuietRunOfThePackageSchemeSaysItWasNotChecked() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = Self.test(["-scheme", "Gizmo-Package", "-quiet"])
        let report = Self.report(of: arguments, lines: [])

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package)?.lines
            == ["inventory: not checked — xcodebuild -quiet prints no line for a test that passed, so there is no list of tests to reconcile"])
    }

    /// Parallel testing names its tests in lines that are not read as outcomes, so reconciling it would name them as never reported; it says so instead.
    @Test
    func aParallelRunOfThePackageSchemeSaysItWasNotChecked() throws {
        let package = try Self.package()
        defer { try? FileManager.default.removeItem(at: package) }
        let arguments = Self.test(["-scheme", "Gizmo-Package", "-parallel-testing-enabled", "YES"])
        let report = Self.report(of: arguments, lines: ["Test case '-[GizmoTests.PalletTests testOne]' passed on 'My Mac - xctest (4242)' (0.001 seconds)"])

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package)?.lines
            == ["inventory: not checked — xcodebuild's parallel testing names its tests in lines this does not read as outcomes"])
    }

    /// The names a real `xcodebuild test` of the package scheme printed on macOS — an XCTest method, one in a nested class under its mangled name, a Swift Testing function at file scope and a parameterized one in a suite — reconcile with every test the package declares and nothing over.
    @Test
    func aCapturedPackageSchemeRunReconcilesWithEveryDeclaredTest() async throws {
        let package = try Self.package(sources: Self.capturedSources)
        defer { try? FileManager.default.removeItem(at: package) }
        _ = try TestSources.makeTempRepo(at: package)
        try await SiftEngine(directory: package).ensureFresh()
        let arguments = Self.test(["-scheme", "Gizmo-Package", "-destination", "platform=macOS"])
        var outcomes = Self.report(of: arguments, lines: Self.capturedRun.components(separatedBy: "\n")).testOutcomes
        outcomes.commandExitCode = 0
        let tested = try #require(RunInventoryCheck.testedPackage(by: arguments, report: Self.report(of: arguments, lines: Self.onePass), workingDirectory: package))

        let check = RunInventoryCheck.check(outcomes, loggedAt: nil, repositoryRoot: package, package: tested, budget: 120)

        #expect(check.lines == ["inventory: 4 declared, 4 reported"])
    }
}

extension XcodebuildInventoryBoundsTests {
    /// One XCTest pass, enough for a run to count as one that reported a test.
    static let onePass = ["Test Case '-[GizmoTests.PalletTests testOne]' passed (0.001 seconds)."]

    /// The test files of the fixture package the captured run below was taken from.
    static let capturedSources = [
        "PalletTests.swift": """
        import XCTest
        @testable import Gizmo

        final class PalletTests: XCTestCase {
            func testOne() { XCTAssertEqual(double(2), 4) }
        }

        enum BayFloor {
            final class PalletTests: XCTestCase {
                func testTwo() { XCTAssertEqual(double(0), 0) }
            }
        }
        """,
        "Shelf.swift": """
        import Testing
        @testable import Gizmo

        @Test func shoutingWorks() { #expect(double(1) == 2) }

        @Suite struct Shelf {
            @Test(arguments: [1, 2, 3]) func stacks(count: Int) { #expect(double(count) == count * 2) }
        }
        """,
    ]

    /// The test lines of `xcodebuild test -scheme Gizmo-Package -destination 'platform=macOS'` over that package (Xcode 26), trimmed of the build and of xcodebuild's own diagnostics, with the zero-width spaces it printed before three Swift Testing lines kept.
    static var capturedRun: String {
        """
        Test Suite 'All tests' started at 2026-10-12 12:44:01.240.
        Test Suite 'GizmoTests.xctest' started at 2026-10-12 12:44:01.240.
        Test Suite 'PalletTests' started at 2026-10-12 12:44:01.240.
        Test Case '-[GizmoTests.PalletTests testOne]' started.
        Test Case '-[GizmoTests.PalletTests testOne]' passed (0.003 seconds).
        Test Suite 'PalletTests' passed at 2026-10-12 12:44:01.246.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
        Test Suite '_TtCO10GizmoTests8BayFloor11PalletTests' started at 2026-10-12 12:44:01.246.
        Test Case '-[_TtCO10GizmoTests8BayFloor11PalletTests testTwo]' started.
        Test Case '-[_TtCO10GizmoTests8BayFloor11PalletTests testTwo]' passed (0.000 seconds).
        Test Suite '_TtCO10GizmoTests8BayFloor11PalletTests' passed at 2026-10-12 12:44:01.246.
        \t Executed 1 test, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        Test Suite 'GizmoTests.xctest' passed at 2026-10-12 12:44:01.246.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.006) seconds
        Test Suite 'All tests' passed at 2026-10-12 12:44:01.246.
        \t Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.007) seconds
        ◇ Test run started.
        ↳ Testing Library Version: 2084
        ↳ Target Platform: arm64e-apple-macos14.0
        ◇ Suite Shelf started.
        ◇ Test shoutingWorks() started.
        ✔ Test shoutingWorks() passed after 0.001 seconds.
        ◇ Test stacks(count:) started.
        ◇ Test case passing 1 argument count → 1 to stacks(count:) started.
        \u{200B}◇ Test case passing 1 argument count → 2 to stacks(count:) started.
        \u{200B}◇ Test case passing 1 argument count → 3 to stacks(count:) started.
        \u{200B}✔ Test stacks(count:) with 3 test cases passed after 0.001 seconds.
        ✔ Suite Shelf passed after 0.001 seconds.
        ✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.

        ** TEST SUCCEEDED **
        """
    }

    /// `xcodebuild test` with `rest` after the action.
    static func test(_ rest: [String]) -> [String] {
        ["xcodebuild", "test"] + rest
    }

    /// The report the filter for `arguments` makes of `lines`, as a run that exited 0.
    static func report(of arguments: [String], lines: [String]) -> RunReport {
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: 0)
    }

    /// A package named `name` with one library target and one test target holding `sources`, in a fresh temporary directory the caller removes.
    static func package(name: String = "Gizmo", sources: [String: String] = [:]) throws -> URL {
        let root = try TemporaryDirectory.make("xcodebuild-inventory").resolvingSymlinksInPath()
        let tests = root.appendingPathComponent("Tests/\(name)Tests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/\(name)"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            products: [.library(name: "\(name)", targets: ["\(name)"]), .library(name: "\(name)Kit", targets: ["\(name)Kit"])],
            targets: [
                .target(name: "\(name)"),
                .target(name: "\(name)Kit"),
                .testTarget(name: "\(name)Tests", dependencies: ["\(name)"]),
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func double(_ value: Int) -> Int { value * 2 }\n".write(to: root.appendingPathComponent("Sources/\(name)/\(name).swift"), atomically: true, encoding: .utf8)
        for (file, source) in sources {
            try source.write(to: tests.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Asserts that a run of `arguments` in `package` that reported a test is not bounded and carries the unchecked line.
    static func expectUnbounded(_ arguments: [String], in package: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let report = report(of: arguments, lines: onePass)

        #expect(RunInventoryCheck.testedPackage(by: arguments, report: report, workingDirectory: package) == nil, sourceLocation: sourceLocation)
        #expect(RunInventoryCheck.unchecked(by: arguments, report: report, workingDirectory: package)?.lines == [unboundedLine], sourceLocation: sourceLocation)
    }
}
