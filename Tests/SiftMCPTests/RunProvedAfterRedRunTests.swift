//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `sift run --proved` refuses a tree whose newest run of the command failed, and a green run after that red one proves it again.
@Suite(.temporaryDirectories)
struct RunProvedAfterRedRunTests {
    @Test
    func aLaterRedRunRefusesTheProofAndALaterGreenRunRestoresIt() throws {
        let directory = try TemporaryDirectory.make("run-proved-after-red")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-proved-after-red-built")
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

        try command.run()
        #expect(throws: ExitCode.success) { try proved.run() }

        try Data().write(to: failSwitch)
        #expect(throws: ExitCode(65)) { try command.run() }
        #expect(RunLedger.inRepository(at: directory).failedRuns.records().count == 1)
        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
        #expect(throws: ExitCode.failure) { try proved.run() }

        // The green must drop the red from the file, not merely outdate it. It runs in a later whole second than
        // the red: the file keeps whole seconds, and a red dated to the green's own second refuses the green.
        let failed = RunLedger.inRepository(at: directory).failedRuns
        try FileManager.default.removeItem(at: failSwitch)
        Thread.sleep(until: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 1))
        try command.run()
        #expect(failed.records().isEmpty)
        #expect(throws: ExitCode.success) { try proved.run() }
    }
}

private extension RunProvedAfterRedRunTests {
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
