//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// A green `sift run` that reaches the ledger after a red of the same run which finished later neither files a proof nor clears that red, so `sift run --proved` refuses the tree.
@Suite(.temporaryDirectories)
struct RunProvedGreenBeforeLaterRedTests {
    @Test
    func aGreenFiledAfterALaterRedLeavesTheTreeRefused() throws {
        let directory = try TemporaryDirectory.make("run-proved-green-before-red")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-proved-green-before-red-built")
        defer { try? FileManager.default.removeItem(at: built) }
        let failSwitch = directory.appendingPathComponent("fail")
        let xcodebuild = directory.appendingPathComponent("xcodebuild")
        try """
        #!/bin/sh
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' started."
        if [ -e '\(failSwitch.path)' ]; then
          echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' failed (0.1 seconds)."
          echo '** TEST FAILED **'
          exit 65
        fi
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' passed (0.1 seconds)."
        echo '** TEST SUCCEEDED **'
        exit 0

        """.write(to: xcodebuild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        let arguments = ["--", xcodebuild.path, "-project", built.appendingPathComponent("Demo.xcodeproj").path, "-scheme", "Demo", "test"]
        var command = try RunCommand.parse(arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = RecordedOutput().output
        var proved = try RunCommand.parse(["--proved"] + arguments)
        proved.writesUnder = directory
        let failed = RunLedger.inRepository(at: directory).failedRuns

        // A red run files the red keyed as this run is; it is then re-dated a minute ahead, standing for a red
        // that finished after the green below and reached the lock before it.
        try Data().write(to: failSwitch)
        #expect(throws: ExitCode(65)) { try command.run() }
        let red = try #require(failed.records().first)
        let later = RunLedger.Record(
            tree: red.tree, command: red.command, toolchain: red.toolchain, finishedAt: Date().addingTimeInterval(60),
            log: red.log, milliseconds: red.milliseconds, checkout: red.checkout, workingDirectory: red.workingDirectory
        )
        failed.record(later)
        try FileManager.default.removeItem(at: failSwitch)

        try command.run()

        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
        #expect(failed.records().count == 1)
        #expect(throws: ExitCode.failure) { try proved.run() }
    }
}

private extension RunProvedGreenBeforeLaterRedTests {
    /// A freshly initialised git repository.
    static func gitRepository(_ purpose: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try TemporaryDirectory.make(purpose)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, sourceLocation: sourceLocation)
        return root
    }
}
