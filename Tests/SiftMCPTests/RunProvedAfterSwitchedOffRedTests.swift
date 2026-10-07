//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `SIFT_RUN_LEDGER=0` stops a run filing a green, never a red: the switch is read per process, so a red run with it off must still revoke a proof filed with it on.
@Suite(.temporaryDirectories)
struct RunProvedAfterSwitchedOffRedTests {
    @Test
    func aRedRunWithTheLedgerOffStillRevokesTheProof() throws {
        let directory = try TemporaryDirectory.make("run-proved-switched-off")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-proved-switched-off-built")
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
        command.environment = [:]
        var switchedOff = command
        switchedOff.environment = [RunLedger.switchName: "0"]
        var proved = try RunCommand.parse(["--proved"] + arguments)
        proved.writesUnder = directory
        proved.environment = [:]
        let ledger = RunLedger.inRepository(at: directory)

        // A green with the switch off proves nothing, and records no green build either.
        try switchedOff.run()
        #expect(ledger.records().isEmpty)
        #expect(RunLedger.greenBuilds(inCheckout: directory).records().isEmpty)

        try command.run()
        #expect(throws: ExitCode.success) { try proved.run() }

        try Data().write(to: failSwitch)
        #expect(throws: ExitCode(65)) { try switchedOff.run() }
        #expect(ledger.records().isEmpty)
        #expect(ledger.failedRuns.records().count == 1)
        #expect(throws: ExitCode.failure) { try proved.run() }
    }
}

private extension RunProvedAfterSwitchedOffRedTests {
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
