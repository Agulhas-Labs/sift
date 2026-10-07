//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers `sift test`'s argument validation, where `--analyse` refuses every flag that describes a build or a run it will not do.
@Suite(.temporaryDirectories)
struct TestCommandTests {
    /// `--analyse`'s answer, through the CLI layer, opens with the freshness header and follows it with the sections in ``TestAnalysisRenderer/render(_:)``'s own order — unpinned before this test.
    @Test
    func theAnswerOpensWithTheHeaderAndKeepsTheRenderersSectionOrder() async throws {
        let root = try TemporaryDirectory.make("test-analyse-header")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("AlphaTests"),
            withIntermediateDirectories: true
        )
        try """
        name: Gizmo
        targets:
          AlphaTests:
            type: bundle.unit-test
            platform: iOS
            sources:
              - path: AlphaTests
        """.write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        try """
        import XCTest

        final class StringHelperTests: XCTestCase {
            func testJoining() {
                XCTAssertTrue(true)
            }
        }
        """.write(to: root.appendingPathComponent("AlphaTests/StringHelperTests.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("TestPlans"),
            withIntermediateDirectories: true
        )
        try """
        {"version":1,"testTargets":[{"skippedTests":["StringHelperTests"],
        "target":{"containerPath":"container:Gizmo.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """.write(to: root.appendingPathComponent("TestPlans/Default.xctestplan"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-b", "main"], ["add", "-A"], ["-c", "user.email=t@example.com", "-c", "user.name=Tester", "commit", "-m", "fixture"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = root
            try process.run()
            process.waitUntilExit()
        }

        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        let command = try TestCommand.parse(["--analyse", "--root", root.resolvingSymlinksInPath().path])
        let (answer, _) = try await command.analysis(workingDirectory: root, registry: registry)

        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.hasPrefix("tree:") == true)
        let planLine = try #require(lines.firstIndex { $0.contains("test plan") && $0.contains("read live off disk") })
        let headlineLine = try #require(lines.firstIndex { $0.contains("sift test --analyse —") })
        let tableHeaderLine = try #require(lines.firstIndex { $0.contains("declared  in a plan  runs  never runs  conditional") })
        let honouredLine = try #require(lines.firstIndex { $0 == "plan exclusions that work and leave no trace (1)" })
        #expect(planLine < headlineLine)
        #expect(headlineLine < tableHeaderLine)
        #expect(tableHeaderLine < honouredLine)
    }

    /// `--analyse` refuses a run's flag by name, in the one sentence every such refusal shares, before anything is opened.
    ///
    /// `--guard-shards` among them: `run()` answers `--analyse` before it reads the watcher's flag, so a pair it accepted would drop the flag without a word.
    @Test(arguments: [
        (["--scheme", "Demo"], "--scheme"),
        (["--guard-shards", "run-1"], "--guard-shards"),
        (["--shard-timeout", "60"], "--shard-timeout"),
    ])
    func analyseRefusesARunsFlagByName(extra: [String], flag: String) {
        #expect(
            Self.refusal(["--analyse"] + extra)
                == "--analyse and \(flag) ask for two different things: --analyse reads the index and the test plans and starts no build, boots no simulator and runs no test, so there is nothing for \(flag) to name. Drop one of the two."
        )
    }

    /// `--sweep` deletes every device a dead run of this checkout recorded and names each one it deleted, through the command's own output and a `simctl` that touches nothing real.
    @Test
    func sweepDeletesADeadRunsRecordedDevicesAndNamesEachOne() async throws {
        let directory = try TemporaryDirectory.make("test-sweep")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q", "-b", "main"]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        let root = try #require(GitContext.discoverRoot(from: directory))
        let prefix = try ShardLedger.devicePrefix(in: root)
        let udids = ["11111111-2222-3333-4444-555555555555", "66666666-7777-8888-9999-000000000000"]
        var ledger = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: prefix, owner: ShardLedger.Identity(pid: 4711, startMicroseconds: 111), started: { _ in nil })
        var names: [String] = []
        for (index, udid) in udids.enumerated() {
            try names.append(ledger.recordIntent(shard: index))
            try ledger.record(udid: udid, forShard: index)
        }
        let deleted = RecordedOutput()
        let recorded = RecordedOutput()
        var command = try TestCommand.parse(["--sweep"])
        command.output = recorded.output
        command.startingDirectory = directory
        command.simctl = { _, arguments in
            if arguments.contains("delete"), let udid = arguments.last {
                deleted.output.emit(udid)
            }
            return SimulatorAccessibility.Output(succeeded: true, standardOutput: arguments.contains("list") ? #"{ "devices": {} }"# : "")
        }

        try await command.run()

        #expect(deleted.printed == udids.map { "\($0)\n" }.joined())
        #expect(recorded.printed == """
        ✔ sift test --sweep — deleted 2 simulators left by runs of this checkout that are no longer running
          deleted \(names[0]) \(udids[0])
          deleted \(names[1]) \(udids[1])

        """)
        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
    }

    /// `--sweep` runs nothing, so it refuses a run's flag, `--analyse` and a pass-through by name, before anything is opened.
    @Test(arguments: [
        (["--shards", "2"], "--shards"),
        (["--shard-timeout", "60"], "--shard-timeout"),
        (["--analyse"], "--analyse"),
        (["--", "-derivedDataPath", "build"], "everything after --"),
    ])
    func sweepRefusesARunsFlagByName(extra: [String], flag: String) {
        #expect(
            Self.refusal(["--sweep"] + extra)
                == "--sweep and \(flag) ask for two different things: --sweep deletes the simulators left by this checkout's runs that are no longer running, and builds, boots and runs nothing. Drop one of the two."
        )
    }

    /// `--shards` above ``ShardPlanner/maximumShards`` is refused with the exact reason before anything is launched.
    @Test
    func shardsAboveTheMaximumAreRefused() throws {
        let command = try TestCommand.parse(["--scheme", "Demo", "--device", "iPhone 17", "--shards", "17"])
        let directory = try TemporaryDirectory.make("test-shards-refused")

        #expect(
            Self.requestRefusal(command, in: directory)
                == "--shards 17 is more than sift will ever plan onto: each shard is a booted simulator — roughly 2–4 GB and a core or two — so 16 is the most, and this host's own default never goes above 3."
        )
    }

    /// `--shards 16`, the maximum, is accepted: validation moves past the bound check to the next requirement (a git repository) rather than refusing it.
    @Test
    func shardsAtTheMaximumAreAccepted() throws {
        let command = try TestCommand.parse(["--scheme", "Demo", "--device", "iPhone 17", "--shards", "16"])
        let directory = try TemporaryDirectory.make("test-shards-accepted")

        #expect(
            Self.requestRefusal(command, in: directory)
                == "sift test runs inside a git repository: the ledger that says which simulators to delete, the shard logs and the test durations all live in that repository's .sift/."
        )
    }

    /// `--shard-timeout` below the sane minimum is refused with the exact reason before anything is launched.
    @Test
    func shardTimeoutBelowTheMinimumIsRefused() throws {
        let command = try TestCommand.parse(["--scheme", "Demo", "--device", "iPhone 17", "--shard-timeout", "29"])
        let directory = try TemporaryDirectory.make("test-shard-timeout-refused")

        #expect(
            Self.requestRefusal(command, in: directory)
                == "--shard-timeout 29 is below 30: a bound that low fires on a healthy shard before xcodebuild has even launched, and costs the whole suite it was given."
        )
    }

    /// `--shard-timeout` at the minimum is accepted, and lowers the floor ``ShardRunner`` reads a predicted shard against.
    @Test
    func shardTimeoutAtTheMinimumLowersTheFloor() throws {
        let command = try TestCommand.parse(["--scheme", "Demo", "--device", "iPhone 17", "--shard-timeout", "30"])
        let directory = try TemporaryDirectory.make("test-shard-timeout-accepted")

        #expect(
            Self.requestRefusal(command, in: directory)
                == "sift test runs inside a git repository: the ledger that says which simulators to delete, the shard logs and the test durations all live in that repository's .sift/."
        )
    }

    /// What `command.request(in:)` refuses with, read as the sentence a person sees.
    private static func requestRefusal(_ command: TestCommand, in directory: URL) -> String? {
        do {
            _ = try command.request(in: directory)
            return nil
        } catch {
            return TestCommand.message(for: error)
        }
    }

    /// What parsing these arguments refuses with, or `nil` where it accepts them.
    ///
    /// Read as the sentence a person sees: a parse wraps a validation failure in ArgumentParser's own error, and the wording is what is pinned.
    private static func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try TestCommand.parse(arguments)
            return nil
        } catch {
            return TestCommand.message(for: error)
        }
    }
}
