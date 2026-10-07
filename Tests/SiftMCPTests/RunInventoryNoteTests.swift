//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import os
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the note a plain `sift run -- swift test` answer carries under its totals: the run's outcomes set against the inventory the index declares, and the exit code it never changes.
@Suite(.temporaryDirectories)
struct RunInventoryNoteTests {
    /// A run that lost a test to a dead process reads green on its own tally; the note names the test that never reported, and the exit code stays the run's 0.
    @Test
    func aRunThatReportedFewerTestsThanDeclaredNamesTheOneThatNeverReported() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo"]), exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: 3 declared, 2 reported — 1 never reported: GizmoTests/PalletTests/testThree()"))
    }

    /// A test that ended twice inside one iteration is named as reported more than once.
    @Test
    func aRunThatReportedATestTwiceNamesIt() async throws {
        let repository = try await Self.indexedPackage()
        let twice = Self.ended(["testOne", "testTwo", "testThree"]) + [Self.passed("testTwo")]
        let (recorded, thrown) = try await Self.run(in: repository, printing: twice, exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: 3 declared, 3 reported — 1 reported more than once: GizmoTests/PalletTests/testTwo()"))
    }

    /// A run that adds up says so in one line, so the reader knows the count was checked, and prints nothing else about it.
    @Test
    func aRunThatAddsUpPrintsOneLineSayingItWasChecked() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo", "testThree"]), exiting: 0)

        #expect(thrown == nil)
        let inventory = recorded.printed.split(separator: "\n").filter { $0.hasPrefix("inventory:") || $0.hasPrefix("  GizmoTests") }
        #expect(inventory == ["inventory: 3 declared, 3 reported"])
    }

    /// A filtered run runs a subset the manifest's targets do not bound, so it is not reconciled and says nothing about the inventory.
    @Test
    func aFilteredRunIsNotReconciled() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne"]), exiting: 0, extraArguments: ["--filter", "PalletTests/testOne"])

        #expect(thrown == nil)
        #expect(!recorded.printed.contains("inventory:"))
    }

    /// `-C`/`--chdir` moves the run to another package as `--package-path` does, so the manifest beside the reader is not the one that ran: a run naming one is not reconciled.
    @Test(arguments: ["-C", "--chdir"])
    func aRunInAnotherDirectoryIsNotReconciled(flag: String) async throws {
        let repository = try await Self.indexedPackage()
        let other = try TemporaryDirectory.make("run-inventory-other")
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne"]), exiting: 0, extraArguments: [flag, other.path])

        #expect(thrown == nil)
        #expect(!recorded.printed.contains("inventory:"))
    }

    /// `-s`/`--specifier` selects tests as surely as `--filter` does, so it is a narrowing option too: a run naming one is not reconciled.
    @Test
    func aSpecifierRunIsNotReconciled() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne"]), exiting: 0, extraArguments: ["-s", "GizmoTests.PalletTests/testOne"])

        #expect(thrown == nil)
        #expect(!recorded.printed.contains("inventory:"))
    }

    /// A `--parallel` run's log names only some of its tests, so it is out of `--against`'s bound and prints nothing.
    @Test
    func aParallelRunIsNotReconciled() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo", "testThree"]), exiting: 0, extraArguments: ["--parallel"])

        #expect(thrown == nil)
        #expect(!recorded.printed.contains("inventory:"))
    }

    /// A fixture whose only declared test opens with `XCTFail` has expected reach zero the same way a manifest with no test target does, but for a different reason: the note says which.
    @Test
    func aFixtureWhoseOnlyDeclaredTestIsLiftedOutPrintsTheLiftedWording() async throws {
        let repository = try await Self.indexedPackage(source: Self.liftedSource)
        let failing = [
            "Test Case '-[GizmoTests.PalletTests testOne]' started.",
            "\(repository.path)/Tests/GizmoTests/PalletTests.swift:5: error: -[GizmoTests.PalletTests testOne] : failed - disabled",
            "Test Case '-[GizmoTests.PalletTests testOne]' failed (0.001 seconds).",
            "Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds",
        ]
        let (recorded, thrown) = try await Self.run(in: repository, printing: failing, exiting: 1)

        #expect(thrown == ExitCode(1))
        #expect(recorded.printed.contains("was lifted out of the counts (1 excluded by XCTFail)"))
        #expect(!recorded.printed.contains("declares no test in the targets"))
    }

    /// Bringing the index up to date and reconciling is given no time at all, so the check answers with the over-budget line rather than waiting.
    @Test
    func aZeroBudgetPrintsTheOverBudgetSkippedLine() async throws {
        let repository = try await Self.indexedPackage()
        var outcomes = RunTestOutcomes()
        for line in Self.ended(["testOne", "testTwo", "testThree"]) {
            outcomes.read(line)
        }

        let check = RunInventoryCheck.check(outcomes, loggedAt: nil, repositoryRoot: repository, budget: 0)

        guard case let .skipped(reason) = check else {
            Issue.record("expected .skipped, got \(check)")
            return
        }

        #expect(reason.contains("longer than 0 s"))
    }

    /// `sift run` gives ``RunInventoryCheck`` a budget of its own to wait on, not a fixed one every invocation shares — a wrapped run given none at all prints the skipped line even though the index is already built and reconciling it takes no real time.
    @Test
    func aRunGivenNoInventoryBudgetPrintsTheOverBudgetSkippedLine() async throws {
        let repository = try await Self.indexedPackage()
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo", "testThree"]), exiting: 0, inventoryBudget: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: not checked — bringing the index up to date and reconciling took longer than 0 s"))
    }

    /// The suite's runs block no thread of the concurrency pool: each is driven from a thread outside it, since a run waits there on an inventory check the pool itself computes, and under load enough blocked runs left the check no thread to run on.
    @Test
    func aRunInThisSuiteBlocksNoThreadOfTheConcurrencyPool() async throws {
        let repository = try await Self.indexedPackage()
        let queues = OSAllocatedUnfairLock(initialState: [String]())

        _ = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo", "testThree"]), exiting: 0) {
            let label = String(cString: __dispatch_queue_get_label(nil))
            queues.withLock { $0.append(label) }
        }
        let printedFrom = queues.withLock { $0 }

        #expect(!printedFrom.isEmpty)
        #expect(!printedFrom.contains { $0.hasSuffix(".cooperative") }, "\(printedFrom)")
    }

    /// A nested package's own manifest bounds it, not the repository root's, so its run is never reconciled against the outer package.
    @Test
    func aNestedPackageRunIsNotReconciled() throws {
        let repository = try Self.package()
        let nested = repository.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "widget", targets: [.testTarget(name: "WidgetTests")])
        """.write(to: nested.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        #expect(!RunInventoryCheck.applies(to: ["swift", "test"], report: Self.nonEmptyReport, workingDirectory: nested, repositoryRoot: repository))
    }

    /// A run in a directory with no manifest at or above it is not one the inventory bounds: the walk up ends at `/`, whose parent is spelled `/..`, and never loops there.
    @Test
    func aRunWithNoManifestAboveItIsNotReconciled() throws {
        let directory = try TemporaryDirectory.make("run-inventory-no-manifest")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!RunInventoryCheck.applies(to: ["swift", "test"], report: Self.nonEmptyReport, workingDirectory: directory, repositoryRoot: directory))
    }

    /// An `xcodebuild` run's set is its scheme's, never the root manifest's, so it is never reconciled.
    @Test
    func anXcodebuildRunIsNotReconciled() throws {
        let repository = try Self.package()

        #expect(!RunInventoryCheck.applies(to: ["xcodebuild", "test"], report: Self.nonEmptyReport, workingDirectory: repository, repositoryRoot: repository))
    }

    /// An index that will not read says so and keeps the wrapped command's exit code, the same as one that is simply not there.
    @Test
    func anUnreadableIndexSaysSoAndKeepsTheExitCode() async throws {
        let repository = try await Self.indexedPackage()
        let indexFile = SiftPaths.cache(in: repository).appendingPathComponent(SiftPaths.indexFileName)
        try Data("not a sift index".utf8).write(to: indexFile)
        let (recorded, thrown) = try await Self.run(in: repository, printing: Self.ended(["testOne", "testTwo", "testThree"]), exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: not checked — the inventory could not be read"))
    }

    /// With no index to read, the note says the check was skipped and why, and a failing run still exits what it was handed.
    @Test
    func aCheckoutWithNoIndexSaysTheCheckWasSkippedAndKeepsTheExitCode() async throws {
        let repository = try Self.package()
        let failing = [
            "Test Case '-[GizmoTests.PalletTests testOne]' started.",
            "\(repository.path)/Tests/GizmoTests/PalletTests.swift:4: error: -[GizmoTests.PalletTests testOne] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
            "Test Case '-[GizmoTests.PalletTests testOne]' failed (0.100 seconds).",
            "Executed 1 test, with 1 failure (0 unexpected) in 0.100 (0.104) seconds",
        ]
        let (recorded, thrown) = try await Self.run(in: repository, printing: failing, exiting: 1)

        #expect(thrown == ExitCode(1))
        #expect(recorded.printed.contains("inventory: not checked — this checkout has no sift index yet"))
    }
}

extension RunInventoryNoteTests {
    /// The default test target's source: one `XCTestCase` declaring three ordinary methods.
    static var threeMethodSource: String {
        """
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {}

            func testTwo() {}

            func testThree() {}
        }
        """
    }

    /// A single method that opens `XCTFail`, so the index declares one test and reconciliation lifts it out of the counts before `expected` ever reaches it.
    static var liftedSource: String {
        """
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {
                XCTFail("disabled")
            }
        }
        """
    }

    /// A committed package with one test target, declaring whatever `source` writes.
    static func package(source: String = threeMethodSource) throws -> URL {
        let root = try TemporaryDirectory.make("run-inventory").resolvingSymlinksInPath()
        let tests = root.appendingPathComponent("Tests/GizmoTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "gizmo",
            targets: [
                .target(name: "GizmoCore"),
                .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"]),
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: tests.appendingPathComponent("PalletTests.swift"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@example.com", "-c", "user.name=Tester", "commit", "-m", "fixture"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        return root
    }

    /// The same package with its index built.
    static func indexedPackage(source: String = threeMethodSource) async throws -> URL {
        let root = try package(source: source)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Bringing a fixture package's index up to date competes with everything else on a loaded machine, not with the reconciliation work `--against` actually does, so the fixture below gives it a budget of its own rather than inheriting the real `RunInventoryCheck.freshenBudget`.
    static let inventoryBudgetForFixtures: TimeInterval = 120

    /// Drives `sift run -- swift test` over a fake `swift` that prints `lines`, scoped to `repository`, and returns what it printed and what it threw; `emitting` runs on the thread that prints each line of the answer.
    ///
    /// Run on a thread of its own, as ``InPlaceAnswerTests/onItsOwnThread(_:)`` runs the answerer: the run blocks its caller while the concurrency pool brings the index up to date, and a suite of runs blocking the pool's own threads can starve it until the inventory check runs out of time.
    static func run(in repository: URL, printing lines: [String], exiting code: Int32, extraArguments: [String] = [], inventoryBudget: TimeInterval = inventoryBudgetForFixtures, emitting: @escaping @Sendable () -> Void = {}) async throws -> (RecordedOutput, ExitCode?) {
        let bin = try TemporaryDirectory.make("run-inventory-bin")
        try (lines.joined(separator: "\n") + "\n").write(to: bin.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\ncat '\(bin.appendingPathComponent("transcript.txt").path)'\nexit \(code)\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let recorded = RecordedOutput()
        let thrown = try await InPlaceAnswerTests.onItsOwnThread {
            Result { () throws -> ExitCode? in
                var command = try RunCommand.parse(["--", swift.path, "test"] + extraArguments)
                command.log = RunUsageLog(fileURL: bin.appendingPathComponent("run.jsonl"))
                command.writesUnder = repository
                command.output = CommandOutput(
                    keepsPartMarker: true,
                    emit: { line in
                        emitting()
                        recorded.output.emit(line)
                    },
                    emitRaw: recorded.output.emitRaw,
                    emitError: recorded.output.emitError
                )
                command.inventoryBudget = inventoryBudget
                command.hintBudget = inventoryBudgetForFixtures
                do {
                    try command.run()
                    return nil
                } catch let exit as ExitCode {
                    return exit
                }
            }
        }.get()
        return (recorded, thrown)
    }

    static func passed(_ method: String) -> String {
        "Test Case '-[GizmoTests.PalletTests \(method)]' passed (0.100 seconds)."
    }

    /// Each method started and passed, closed by XCTest's own count of them.
    static func ended(_ methods: [String]) -> [String] {
        methods.flatMap { ["Test Case '-[GizmoTests.PalletTests \($0)]' started.", passed($0)] }
            + ["Executed \(methods.count) tests, with 0 failures (0 unexpected) in 0.200 (0.204) seconds"]
    }

    /// A report that reported at least one test, which is all `RunInventoryCheck.applies` asks of it beyond the command shape and scope it is given.
    static var nonEmptyReport: RunReport {
        var outcomes = RunTestOutcomes()
        outcomes.read("Test Case '-[WidgetTests.WidgetTests testOne]' passed (0.100 seconds).")
        return RunReport(errors: [], warnings: [], testFailures: [], summaryLines: [], contract: .diagnostics, verdict: nil, tally: nil, totalLines: 0, testOutcomes: outcomes)
    }
}

// MARK: - Result lines lost

extension RunInventoryNoteTests {
    /// Swift Testing printed two tests' start lines and no result lines, while their suite and the run both passed: the note says their result lines were lost and never that they went unreported.
    @Test
    func startedTestsUnderAPassingSuiteAndRunAreResultLinesLostNotNeverReported() async throws {
        let repository = try await Self.indexedPackage(source: Self.swiftTestingSource)
        let lines = Self.swiftTesting(started: ["anOrdinaryPass", "countIsOne", "dimLampWorks"], passed: ["anOrdinaryPass"])
        let (recorded, thrown) = try await Self.run(in: repository, printing: lines, exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: 3 declared, 1 reported — 2 result lines lost, the tests passing by their suite and run summaries: GizmoTests/PalletTests/countIsOne(), GizmoTests/PalletTests/dimLampWorks()"))
        #expect(!recorded.printed.contains("never reported"))
    }

    /// A test that printed no start line at all is still never reported, beside one whose result line was lost in the same run.
    @Test
    func aTestWithNoStartLineIsStillNeverReported() async throws {
        let repository = try await Self.indexedPackage(source: Self.swiftTestingSource)
        let lines = Self.swiftTesting(started: ["anOrdinaryPass", "countIsOne"], passed: ["anOrdinaryPass"])
        let (recorded, thrown) = try await Self.run(in: repository, printing: lines, exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: 3 declared, 1 reported — 1 never reported: GizmoTests/PalletTests/dimLampWorks() · 1 result line lost, the tests passing by their suite and run summaries: GizmoTests/PalletTests/countIsOne()"))
    }

    /// A suite that never printed its ending, a run summary that failed and a run that printed no summary each leave a started test never reported: nothing passing accounts for it.
    @Test(arguments: [
        (suite: nil, run: "✔ Test run with 3 tests in 1 suite passed after 0.002 seconds."),
        (suite: "✔ Suite PalletTests passed after 0.002 seconds.", run: "✘ Test run with 3 tests in 1 suite failed after 0.002 seconds with 1 issue."),
        (suite: "✔ Suite PalletTests passed after 0.002 seconds.", run: nil),
    ] as [(suite: String?, run: String?)])
    func aStartedTestNoPassingSuiteAndRunAccountForIsStillNeverReported(suite: String?, run: String?) async throws {
        let repository = try await Self.indexedPackage(source: Self.swiftTestingSource)
        let lines = Self.swiftTesting(started: ["anOrdinaryPass", "countIsOne", "dimLampWorks"], passed: ["anOrdinaryPass", "dimLampWorks"], suite: suite, run: run)
        let (recorded, _) = try await Self.run(in: repository, printing: lines, exiting: 0)

        #expect(recorded.printed.contains("inventory: 3 declared, 2 reported — 1 never reported: GizmoTests/PalletTests/countIsOne()"))
        #expect(!recorded.printed.contains("result line"))
    }

    /// The started test's own run passed with its suite, and a later run failed, so the command exited non-zero: it failed somewhere, no summary it printed accounts for a missing line, and the test was never reported.
    @Test
    func aStartedTestUnderACommandThatExitedNonZeroIsStillNeverReported() async throws {
        let repository = try await Self.indexedPackage(source: Self.swiftTestingSource)
        let lines = Self.swiftTesting(started: ["anOrdinaryPass", "countIsOne", "dimLampWorks"], passed: ["anOrdinaryPass", "dimLampWorks"]) + [
            "◇ Test run started.",
            "◇ Test shoutingWorks() started.",
            "✘ Test shoutingWorks() failed after 0.001 seconds with 1 issue.",
            "✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.",
        ]
        let (recorded, _) = try await Self.run(in: repository, printing: lines, exiting: 1)

        #expect(recorded.printed.contains("inventory: 3 declared, 2 reported — 1 never reported: GizmoTests/PalletTests/countIsOne()"))
        #expect(!recorded.printed.contains("result line"))
    }

    /// `test --analyse --against` a log whose second run crashed after starting a test, where only the first run printed the suite's pass line and a passing summary, stays red and names the test missing.
    @Test
    func analyseAgainstALogWhoseSecondRunCrashedStaysRed() async throws {
        let repository = try await Self.indexedPackage(source: Self.swiftTestingSource)
        let lines = [
            "◇ Test run started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "◇ Test dimLampWorks() started.",
            "✔ Test dimLampWorks() passed after 0.001 seconds.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.",
            "◇ Test run started.",
            "◇ Test countIsOne() started.",
            "Fatal error: boom",
        ]
        let log = repository.appendingPathComponent("crashed.log")
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))

        let command = try TestCommand.parse(["--analyse", "--against", log.path, "--root", repository.path])
        let (answer, isGreen) = try await command.analysis(workingDirectory: repository, registry: registry)

        #expect(!isGreen)
        #expect(answer.contains("✘ sift test --analyse --against — 1 missing"))
        #expect(answer.contains("GizmoTests/PalletTests/countIsOne()"))
        #expect(!answer.contains("lines lost"))
    }
}

/// A run whose test process crashed never prints the clean inventory line, even where every test the index declares reported.
extension RunInventoryNoteTests {
    /// Every declared XCTest passed while a Swift Testing process the index declares nothing for trapped in `topples()`: the counts agree, and the line still names the crash rather than reading clean.
    @Test
    func aCrashedRunWhoseDeclaredTestsAllReportedStillNamesTheCrashOnItsInventoryLine() async throws {
        let repository = try await Self.indexedPackage()
        let helper = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
        let lines = Self.ended(["testOne", "testTwo", "testThree"]) + [
            "error: Process '\(helper) --test-bundle-path \(repository.path)/GizmoTests' exited with unexpected signal code 5",
            "◇ Test run started.",
            "◇ Test topples() started.",
            "GizmoTests/PalletTests.swift:4: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
        ]
        let (recorded, thrown) = try await Self.run(in: repository, printing: lines, exiting: 1)

        #expect(thrown == ExitCode(1))
        let inventory = recorded.printed.split(separator: "\n").filter { $0.hasPrefix("inventory:") }
        #expect(inventory == ["inventory: 3 declared, 3 reported — test process crashed; 1 started and never ended; the log does not say how many selected tests never started"])
    }
}

/// A run that executed no test, though the index declares some, is reconciled as zero reported rather than refused as a log that is not a run's output.
extension RunInventoryNoteTests {
    /// Both frameworks closed on a count of 0 over a target the index declares three tests in: the line names the three that never reported, and the run still exits 4.
    @Test
    func aRunThatExecutedNoTestNamesEveryDeclaredTestAsNeverReported() async throws {
        let repository = try await Self.indexedPackage()
        let zero = [
            "Test Suite 'All tests' started at 2026-10-02 06:49:41.667.",
            "Test Suite 'All tests' passed at 2026-10-02 06:49:41.668.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "◇ Test run started.",
            "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.",
        ]
        let (recorded, thrown) = try await Self.run(in: repository, printing: zero, exiting: 0)

        #expect(thrown == ExitCode(RunTestSelector.exitCode))
        let inventory = recorded.printed.split(separator: "\n").filter { $0.hasPrefix("inventory:") }
        #expect(inventory.count == 1, "\(recorded.printed)")
        #expect(inventory.first?.hasPrefix("inventory: 3 declared, 0 reported — 3 never reported: ") == true, "\(recorded.printed)")
        #expect(inventory.first?.contains("GizmoTests/PalletTests/testThree()") == true, "\(recorded.printed)")
    }
}

private extension RunInventoryNoteTests {
    /// One Swift Testing suite declaring three tests.
    static var swiftTestingSource: String {
        """
        import Testing

        struct PalletTests {
            @Test func anOrdinaryPass() {}
            @Test func countIsOne() {}
            @Test func dimLampWorks() {}
        }
        """
    }

    /// A Swift Testing run that started `started`, printed a result line for `passed` alone, and closed on `suite` and `run` where they are given.
    static func swiftTesting(
        started: [String],
        passed: [String],
        suite: String? = "✔ Suite PalletTests passed after 0.002 seconds.",
        run: String? = "✔ Test run with 3 tests in 1 suite passed after 0.002 seconds."
    ) -> [String] {
        ["◇ Test run started.", "◇ Suite PalletTests started."]
            + started.map { "◇ Test \($0)() started." }
            + passed.map { "✔ Test \($0)() passed after 0.001 seconds." }
            + [suite, run].compactMap(\.self)
    }
}
