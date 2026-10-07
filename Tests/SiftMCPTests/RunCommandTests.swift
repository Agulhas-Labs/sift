//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers `run`'s argument handling, where passthrough capture and ArgumentParser's own conventions collide.
@Suite(.temporaryDirectories)
struct RunCommandTests {
    /// Asking this subcommand to explain itself must not exec `/usr/bin/env --help`.
    ///
    /// `.captureForPassthrough` hands `-h` to the wrapped command, which is exactly what makes the flag reachable for `swift test -h` — but with nothing else on the line there is no wrapped command to hand it to.
    @Test
    func askingForHelpDescribesTheSubcommandRatherThanRunningEnv() throws {
        for spelling in ["-h", "--help"] {
            let command = try RunCommand.parse([spelling])

            #expect(throws: CleanExit.self) {
                try command.run()
            }
        }
    }

    /// A wrapped command that carries `-h` of its own is still passed through — the help path is the *sole* argument, not any argument.
    @Test
    func helpInsideAWrappedCommandIsNotThisCommandsHelp() throws {
        let command = try RunCommand.parse(["--", "swift", "test", "-h"])

        #expect(command.command == ["--", "swift", "test", "-h"])
    }

    /// Both spellings of the terminator reach the same command.
    @Test
    func theTerminatorIsOptional() throws {
        #expect(try RunCommand.parse(["--", "swift", "build"]).command == ["--", "swift", "build"])
        #expect(try RunCommand.parse(["swift", "build"]).command == ["swift", "build"])
    }

    /// `report`'s raw-log fallback reads whether this run's failures have the shape of an empty accessibility tree from the outcome itself rather than assuming they do not — the wiring a hardcoded `note(failuresReadEmptyTrees: false)` at the call site would silently defeat.
    ///
    /// A device that read on throughout stays silent unless the failures it is beside read empty trees (`SimulatorAccessibility.Restoration.note(failuresReadEmptyTrees:)`), so this asserts on that device's note directly: a call site that always passed `false` would report it silent even here, where the failures plainly read one.
    @Test
    func theRawLogFallbacksNotesAskWhetherFailuresReadEmptyTrees() throws {
        let failures = Self.emptyTreeMessages.enumerated().map { index, message in
            RunTestFailure(name: "aTestNamed\(index)()", location: "\(Self.emptyTreeFiles[index]).swift:\(index + 1):9", message: message)
        }
        let report = RunReport(
            errors: [],
            warnings: [],
            testFailures: failures,
            summaryLines: [],
            contract: .diagnostics,
            verdict: nil,
            tally: nil,
            totalLines: 10
        )
        let root = try Self.makeCleanGitRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: 65, report: report, log: nil, repositoryRoot: root)
        let accessibility = [SimulatorAccessibility.Restoration(udid: Self.emptyTreeUdid, state: .alreadyOn)]

        let notes = RunCommand.accessibilityNotes(for: outcome, workingDirectory: root, accessibility: accessibility)

        #expect(notes.count == 1)
        #expect(notes.first?.contains("yet the failures read empty trees") == true)
    }

    /// `--without` repeats, so two files can be set aside as one unit without naming the directory above them — which would take every unrelated edit under it along.
    ///
    /// One pathspec per flag is the whole of what the parser can take: passthrough capture reads a second one written beside the first as part of the wrapped command, and `RunWithoutArguments` refuses that shape by name.
    @Test
    func withoutRepeatsOncePerPathspec() throws {
        let command = try RunCommand.parse([
            "--without", "Sources/Depot.swift",
            "--without", "Sources/Orchard.swift",
            "--", "swift", "test", "--filter", "WidgetTests",
        ])

        #expect(command.without == ["Sources/Depot.swift", "Sources/Orchard.swift"])
        #expect(command.command == ["--", "swift", "test", "--filter", "WidgetTests"])
    }

    /// `--proved` beside a set-aside is refused rather than answered with the set-aside dropped: exit 1 from the proved question would read as "the change did not earn its test".
    ///
    /// `--since` needs `--without`, so refusing the one refuses both spellings; the bare `--since` pair keeps its own refusal.
    @Test
    func provedRefusesASetAsideRatherThanIgnoringIt() throws {
        for extra in [["--without", "Sources/Depot.swift"], ["--without", "Sources/Depot.swift", "--since", "HEAD~1"]] {
            let command = try RunCommand.parse(["--proved"] + extra + ["--", "swift", "test"])

            #expect(throws: ValidationError.self) {
                try command.run()
            }
        }
    }

    /// `--root` before the command is refused by name: left in the command it reached `env`, which failed with `illegal option -- r`.
    @Test
    func rootBeforeTheCommandIsRefusedByName() throws {
        let command = try RunCommand.parse(["--root", "/tmp/worktree", "--", "swift", "test"])

        #expect(throws: ValidationError.self) {
            try command.run()
        }
    }

    /// A wrapped run files one line, and every field on it comes from the run that just happened.
    ///
    /// The log is handed in rather than reached for: the shared per-user log follows the process's `HOME`, which one test cannot move without moving it for every suite running beside it. What would go unasserted is not decoration — the kind decides which section of `usage` counts this run, the exit code decides `nonzeroExits`, the line pair is the whole suppression figure, and the root is what `--root` scopes by.
    @Test
    func aWrappedRunFilesOneLineCarryingItsOwnKindExitLinesAndRoot() throws {
        let directory = try TemporaryDirectory.make("run-command")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeSwift(
            in: directory,
            printing: "/tmp/Widget.swift:3:1: error: cannot find 'Gadget' in scope\nBuilding for debugging...\n",
            exiting: 65
        )
        let file = directory.appendingPathComponent("run.jsonl")

        var command = try RunCommand.parse(["--", swift.path, "test"])
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = directory
        #expect(throws: ExitCode.self) {
            try command.run()
        }

        let line = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        let recorded = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(recorded["kind"] as? String == "swift test")
        #expect(recorded["exit"] as? Int == 65)
        #expect(recorded["total"] as? Int == 2)
        // `shown` is what the answer cost, counted on the text that went out: a headline, the note that
        // no summary was found, a blank line and the one error, the `totals:` line a `swift test` answer
        // always closes its content on, and the receipt. It is not the
        // filter's count of input lines that survived somewhere, which is 1 here and can run to thousands
        // on an answer of a few dozen lines.
        #expect(recorded["shown"] as? Int == 6)
        // `run` files itself under the repository it ran in, which it discovers rather than being told —
        // the same discovery, asked here independently, has to agree with what was written.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        #expect(recorded["root"] as? String == GitContext.discoverRoot(from: cwd)?.path)
        // The tree it started on, as a SHA-256 in hex: compared by shape rather than recomputed, because the
        // checkout it hashed is the one this suite is running in and may be written to by another test.
        let tree = try #require(recorded["tree"] as? String)
        #expect(tree.count == 64 && tree.allSatisfy(\.isHexDigit))
        let invocation = try #require(recorded["invocation"] as? String)
        #expect(invocation.count == 64 && invocation.allSatisfy(\.isHexDigit))
    }

    /// A build can fail no test, so it files no tree in the run log, whatever it hashes for the stop gate's record.
    @Test
    func aWrappedBuildFilesNoTree() throws {
        let directory = try TemporaryDirectory.make("run-command")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeSwift(in: directory, printing: "Build complete!\n", exiting: 0)
        let file = directory.appendingPathComponent("run.jsonl")

        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = directory
        try command.run()

        let line = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        let recorded = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        #expect(recorded["kind"] as? String == "swift build")
        #expect(recorded["tree"] == nil)
    }

    /// A successful build prints `Build complete!`, which `RunVerdict.state(of:)` reads as `.succeeded` exactly as a green test does, so a build once satisfied `provedGreen` too and was written into the ledger as proof of a tree no test ever read.
    ///
    /// It records nothing now: the tree key `prove(_:bundles:selector:ran:in:milliseconds:)` needs is taken only for a command that executes tests.
    @Test
    func aWrappedBuildThatSucceedsRecordsNoProof() throws {
        let directory = try TemporaryDirectory.make("run-command-build-proof")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeSwift(in: directory, printing: "Build complete!\n", exiting: 0)

        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        try command.run()

        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
    }

    /// A wrapped `xcodebuild test` that prints a target-qualified pass seeds the durations store under ``RunCommand/writesUnder``, never this checkout's own, so the serial run people already do is not wasted on the first sharded one.
    @Test
    func aWrappedXcodebuildTestSeedsTheDurationsStore() throws {
        let checkout = try #require(GitContext.discoverRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let directory = try TemporaryDirectory.make("run-command-durations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeXcodebuild(
            in: directory,
            printing: """
            Test Case '-[SeedingUITests.SeededOnceTests testSeededByAWrappedRun]' started.
            Test Case '-[SeedingUITests.SeededOnceTests testSeededByAWrappedRun]' passed (1.5 seconds).
            ** TEST SUCCEEDED **
            """,
            exiting: 0
        )

        var command = try RunCommand.parse(["--", xcodebuild.path, "test", "-scheme", "Demo"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        // The wrapped fake exits proved green, and `root` is this checkout's own — same as a real
        // invocation's would be. Everything the run writes for itself is scoped to this fixture's own
        // directory instead: without that, the proof lands in this checkout's real `.sift/proved-runs.json`,
        // the timings in the store the sibling test below is about to read — two of them writing the real
        // store in parallel each overwrite the other's — and the transcript in the developer's run log.
        command.writesUnder = directory
        let checkoutDurations = try? Data(contentsOf: TestDurationStore.fileURL(in: checkout))
        // The assertion below is `nil == nil` on a checkout that has never run a sharded suite, so the seam
        // regressing is caught by the median on this fixture's own root instead — and a failing assertion does
        // not undo a write. Whatever this run put in the checkout's store goes back to what was there, so a
        // regression costs a red test and not the developer's own timings.
        defer {
            let file = TestDurationStore.fileURL(in: checkout)
            if let checkoutDurations {
                try? checkoutDurations.write(to: file)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try command.run()
        let store = TestDurationStore(repositoryRoot: directory)

        #expect(store.median(for: "SeedingUITests/SeededOnceTests/testSeededByAWrappedRun()") == 1.5)
        #expect((try? Data(contentsOf: TestDurationStore.fileURL(in: checkout))) == checkoutDurations)
    }

    /// A run log that is not valid UTF-8 elsewhere still re-arms the device it named no `-destination` for: the `PLATFORM_NAME` marker is ASCII, so a lossy read finds it where `String(data:encoding:)` would return `nil` on the invalid byte and lose the re-arm note along with the whole log.
    @Test
    func aRunLogWithAnInvalidByteStillReadsItsReArmMarker() throws {
        let directory = try TemporaryDirectory.make("run-command-invalid-utf8-log")
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = Data("""
        Test Case '-[SeedingUITests.SeededOnceTests testInvalidUTF8]' started.
        Test Case '-[SeedingUITests.SeededOnceTests testInvalidUTF8]' passed (0.1 seconds).

        """.utf8)
        payload.append(0xFF) // a byte no UTF-8 sequence can start with
        payload.append(Data("""

            export PLATFORM_NAME\\=iphonesimulator
        ** TEST SUCCEEDED **

        """.utf8))
        let payloadURL = directory.appendingPathComponent("transcript.txt")
        try payload.write(to: payloadURL)
        let script = directory.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\ncat '\(payloadURL.path)'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", script.path, "test", "-scheme", "Demo"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output

        try command.run()

        #expect(recorded.printed.contains("no device determined"))
    }

    /// A run that proves green files its record into the ledger under ``RunCommand/writesUnder``, never into this checkout's own ledger — the leak where an in-process fixture inherits the test process's real cwd and so discovers this checkout as `root` the same way a real invocation would.
    ///
    /// The checkout's ledger is shared by every worktree of the repository, so a parallel `sift run` elsewhere may add to it while this runs; the check looks for this run's own record, whose command names the fixture directory, rather than for an unchanged file.
    @Test
    func aProvedGreenRunRecordsIntoTheScopedLedgerNeverTheCheckoutsOwn() throws {
        let root = try #require(GitContext.discoverRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let checkoutLedger = RunLedger.inRepository(at: root)

        let directory = try TemporaryDirectory.make("run-command-ledger")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeXcodebuild(
            in: directory,
            printing: """
            Test Case '-[LedgerScopeUITests.LedgerScopedTests testProvedByAWrappedRun]' started.
            Test Case '-[LedgerScopeUITests.LedgerScopedTests testProvedByAWrappedRun]' passed (0.1 seconds).
            ** TEST SUCCEEDED **
            """,
            exiting: 0
        )
        var command = try RunCommand.parse(["--", xcodebuild.path, "test", "-scheme", "Demo"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        try command.run()

        let recorded = RunLedger.inRepository(at: directory).records()

        #expect(recorded.count == 1)
        #expect(recorded.first?.checkout == root.path)
        #expect(!checkoutLedger.records().contains { $0.command.contains(directory.path) })
    }

    /// A run that named its tests and executed none exits ``RunTestSelector/exitCode`` rather than the 0 it was handed, and files no proof: `xcodebuild` called it `** TEST SUCCEEDED **`.
    @Test
    func aSelectedRunThatExecutedNothingExitsItsOwnCodeAndProvesNothing() throws {
        let directory = try TemporaryDirectory.make("run-command-no-match")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeXcodebuild(
            in: directory,
            printing: """
            Test Suite 'All tests' started at 2000-01-01 12:00:03.454.
            Test Suite 'All tests' passed at 2000-01-01 12:00:03.455.
            \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
            ** TEST SUCCEEDED **
            """,
            exiting: 0
        )
        var command = try RunCommand.parse(["--", xcodebuild.path, "test", "-scheme", "Demo", "-only-testing:LedgerScopeUITests/LedgerScopedTests/testProvedByAWrappedRun"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        #expect(throws: ExitCode(RunTestSelector.exitCode)) {
            try command.run()
        }
        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
    }

    /// Parallel testing that started a suite on its runner and ran no test under it — what `xcodebuild` printed for an XCTest method that does not exist — is the same zero, with the same exit and no proof.
    @Test
    func aParallelRunnerThatRanNoTestExitsItsOwnCodeAndProvesNothing() throws {
        let directory = try TemporaryDirectory.make("run-command-parallel-no-match")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeXcodebuild(
            in: directory,
            printing: """
            ** TEST EXECUTE SUCCEEDED **

            Testing started
            Test suite 'Legacy' started on 'My Mac - xctest (3906)'
            """,
            exiting: 0
        )
        var command = try RunCommand.parse(["--", xcodebuild.path, "-parallel-testing-enabled", "YES", "test-without-building", "-scheme", "Demo", "-only-testing:GadgetTests/Legacy/testNope"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        #expect(throws: ExitCode(RunTestSelector.exitCode)) {
            try command.run()
        }
        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
    }

    /// A non-quiet selected run that printed its success banner and no test line exits 4 and files no proof: a Swift Testing function named without its `()` under parallel testing prints `** TEST EXECUTE SUCCEEDED **` and not one test.
    @Test
    func aPrintedBannerOverNoTestLineExitsFour() throws {
        let directory = try TemporaryDirectory.make("run-command-selected-unproved")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeXcodebuild(in: directory, printing: "** TEST EXECUTE SUCCEEDED **\n\nTesting started", exiting: 0)
        var command = try RunCommand.parse(["--", xcodebuild.path, "-parallel-testing-enabled", "YES", "test-without-building", "-scheme", "Demo", "-only-testing:GadgetTests/Modern/aTrendIsRead"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        #expect(throws: ExitCode(RunTestSelector.exitCode)) {
            try command.run()
        }

        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
    }

    /// A filtered run whose tests did not compile exits ``RunTestSelector/didNotBuildExitCode`` rather than the 1 a failing test exits with, and the same build failure unfiltered passes its 1 through.
    @Test(arguments: [(["test", "--filter", "WidgetTests"], RunTestSelector.didNotBuildExitCode), (["test"], 1)] as [([String], Int32)])
    func aFilteredRunThatDidNotBuildExitsItsOwnCode(arguments: [String], expected: Int32) throws {
        let directory = try TemporaryDirectory.make("run-command-did-not-build")
        defer { try? FileManager.default.removeItem(at: directory) }
        // The lines that decide it, from `Fixtures/RunOutput/swift-test-filter-compile-error.txt`.
        let swift = try Self.fakeSwift(
            in: directory,
            printing: """
            Building for debugging...
            /Users/dev/Widget/Tests/WidgetTests/WidgetTests.swift:10:33: error: value of type 'Widget' has no member 'tripled'
            [121 / 127] WidgetTests-product
            error: Build failed
            error: fatalError
            """,
            exiting: 1
        )
        var command = try RunCommand.parse(["--", swift.path] + arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        #expect(throws: ExitCode(expected)) {
            try command.run()
        }
    }

    /// A selected run whose log is silent about its tests, rather than counting zero of them, keeps the exit it was handed: a `-quiet` pass, a `--parallel` pass that printed only progress, and a `build-for-testing` that runs no test at all.
    @Test(arguments: [
        ("xcodebuild", ["-quiet", "test", "-scheme", "Demo", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"], "Testing started"),
        ("xcodebuild", ["build-for-testing", "-scheme", "Demo", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"], "** TEST BUILD SUCCEEDED **"),
        ("swift", ["test", "--filter", "testGamma", "--parallel"], "[1/1] Testing GadgetTests.LegacyTests/testGamma"),
    ])
    func aSelectedRunSilentAboutItsTestsExitsWhatItWasHanded(tool: String, arguments: [String], output: String) throws {
        let directory = try TemporaryDirectory.make("run-command-silent-selection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = tool == "swift"
            ? try Self.fakeSwift(in: directory, printing: output, exiting: 0)
            : try Self.fakeXcodebuild(in: directory, printing: output, exiting: 0)
        var command = try RunCommand.parse(["--", fake.path] + arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        try command.run()
    }

    /// A wrapped run writes its transcript under ``RunCommand/writesUnder``, and leaves the run log of the directory it was launched from exactly as it found it.
    ///
    /// Not noise but loss: only ``RunLog/keptLogs`` transcripts are kept, so three fixtures driving `RunCommand` in-process evict most of a developer's real ones on every `swift test` — including the one a receipt printed seconds earlier and told them to open.
    @Test
    func aWrappedRunWritesItsTranscriptWhereItIsScopedNeverTheCheckoutsOwn() throws {
        // The working directory, which is what the transcript is written under, rather than the repository
        // root the ledger and the durations store are keyed by. They are the same directory when the suite is
        // run from the package root and not otherwise, and a pin that watched the root would compare a
        // directory a regression never touched against itself.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cwdRuns = SiftPaths.cache(in: cwd).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
        let before = Self.transcripts(in: cwdRuns)

        let directory = try TemporaryDirectory.make("run-command-transcript")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeSwift(
            in: directory,
            printing: "/tmp/Sprocket.swift:9:1: error: cannot find 'Cog' in scope\nBuilding for debugging...\n",
            exiting: 65
        )

        var command = try RunCommand.parse(["--", swift.path, "test"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        #expect(throws: ExitCode.self) {
            try command.run()
        }

        // The leak first, and before anything that can throw: a `#require` on the scoped directory ends the
        // test where it stands, and this is the assertion the whole seam exists for. By name rather than by
        // count, because the leak prunes as well as writes — a run log that lost a real transcript and
        // gained a fixture's holds the same number of files as before.
        #expect(Self.transcripts(in: cwdRuns).map(\.lastPathComponent) == before.map(\.lastPathComponent))

        let scoped = Self.transcripts(in: SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true))
        #expect(scoped.count == 1)
        let written = try #require(scoped.first)
        let transcript = try String(contentsOf: written, encoding: .utf8)
        #expect(transcript.contains("cannot find 'Cog' in scope"))
    }

    /// A run whose writes are scoped refuses on the set-aside of the repository they are scoped to, never on whatever is out in the checkout the test process runs in.
    @Test
    func aScopedRunRefusesOnTheSetAsideWhereItsWritesAreScoped() throws {
        let root = try Self.makeCleanGitRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "changed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try SetAside.capture(pathspecs: ["README.md"], from: root, into: SetAsideStore(repositoryRoot: root))
        let file = root.appendingPathComponent("run.jsonl")

        var command = try RunCommand.parse(["--", "/usr/bin/true"])
        command.log = RunUsageLog(fileURL: file)
        command.writesUnder = root

        #expect(throws: ExitCode.failure) {
            try command.run()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path), "a refused run starts nothing and files nothing")
    }

    /// A repeated `--without-line` is refused rather than silently keeping only the last one: a run sets aside one line, and dropping the rest without saying so would leave a caller believing more was set aside than was.
    @Test
    func aRepeatedWithoutLineIsRefusedNamingEveryLineGiven() throws {
        let command = try RunCommand.parse([
            "--without-line", "A.swift:74",
            "--without-line", "B.swift:190",
            "--", "swift", "test", "--filter", "WidgetTests",
        ])

        #expect(throws: ValidationError.self) {
            try command.run()
        }
        do {
            try command.run()
        } catch let error as ValidationError {
            #expect(error.message.contains("A.swift:74"))
            #expect(error.message.contains("B.swift:190"))
        }
    }

    /// The finished transcripts in `directory`, in a stable order, and none where there is no such directory.
    private static func transcripts(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("run-") && $0.hasSuffix(".log") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Eight files, one per message below, wide enough a spread that the shared value crosses more than one signature.
    private static let emptyTreeFiles = [
        "BinLabelTests", "ChartGridTests", "ConveyorBeltTests", "HopperGaugeTests",
        "PalletTests", "BackorderTests", "GridTests", "ListingTests",
    ]

    /// Six messages reading an empty accessibility tree over three signatures, and two that read something else — the same shape `RunDominantFailureTests` proves the detector reads as an empty tree.
    private static let emptyTreeMessages = [
        #"Expectation failed: (labels → "").contains(bay.signage → "Sprockets")"#,
        #"Expectation failed: (labels → "").contains(crate.signage → "Rivets")"#,
        #"Expectation failed: (labels → "") == (expected → "Cogs")"#,
        #"Expectation failed: (labels → "").contains(bay.signage → "Washers")"#,
        #"Expectation failed: (labels → "").contains(crate.signage → "Dowels")"#,
        #"Expectation failed: (labels → "") == (expected → "Shims")"#,
        "Expectation failed: (stacked → 3) == (wanted → 4)",
        "Expectation failed: (marker → nil) != nil",
    ]

    /// The one simulator these failures are read beside.
    private static var emptyTreeUdid: String {
        "00000000-0000-0000-0000-000000000000"
    }

    /// A stand-in `xcodebuild` that prints a fixed transcript and exits with a chosen code, named `xcodebuild` because that is the whole of what `RunCommandKind` recognises.
    private static func fakeXcodebuild(in directory: URL, printing output: String, exiting code: Int32) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A stand-in `swift` that prints a fixed transcript and exits with a chosen code.
    ///
    /// Named `swift` because that is the whole of what `RunCommandKind` recognises — the last path component — so a wrapped run of a real toolchain is reproduced without waiting on one.
    private static func fakeSwift(in directory: URL, printing output: String, exiting code: Int32) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("swift")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private extension RunCommandTests {
    /// A disposable, freshly committed git repository — the shape `RunDominantFailureClass` needs to read `0 in changed files` rather than `not a git repository`, which the empty-tree clause requires just as strictly as the value or the expression.
    static func makeCleanGitRepo() throws -> URL {
        let root = try TemporaryDirectory.make("run-command-notes-repo")
        for arguments in [
            ["init", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Tester"],
        ] {
            try Self.runGit(arguments, in: root)
        }
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "-A"], in: root)
        try Self.runGit(["commit", "-m", "seed"], in: root)
        return root.resolvingSymlinksInPath()
    }

    @discardableResult
    static func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            struct GitError: Error { let message: String }
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed in test: \(text)")
        }
        return String(data: output, encoding: .utf8) ?? ""
    }
}
