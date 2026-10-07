//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// A run of tests that exits 0 without proving its tree is filed as red, so `sift run --proved` stops standing on an older green run of the same command on the same content.
@Suite(.temporaryDirectories)
struct RunProvedAfterQuietPassTests {
    @Test
    func aPassReadFromAQuietExitCodeRevokesTheOlderProof() throws {
        let directory = try TemporaryDirectory.make("run-proved-after-quiet")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-proved-after-quiet-built")
        defer { try? FileManager.default.removeItem(at: built) }
        let silentSwitch = directory.appendingPathComponent("silent")
        let xcodebuild = directory.appendingPathComponent("xcodebuild")
        try """
        #!/bin/sh
        if [ -e '\(silentSwitch.path)' ]; then
          exit 0
        fi
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' started."
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' passed (0.1 seconds)."
        echo '** TEST SUCCEEDED **'
        exit 0

        """.write(to: xcodebuild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        let arguments = ["--", xcodebuild.path, "-quiet", "-project", built.appendingPathComponent("Demo.xcodeproj").path, "-scheme", "Demo", "test"]
        var command = try RunCommand.parse(arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = RecordedOutput().output
        var proved = try RunCommand.parse(["--proved"] + arguments)
        proved.writesUnder = directory

        try command.run()
        #expect(throws: ExitCode.success) { try proved.run() }

        try Data().write(to: silentSwitch)
        try command.run()
        #expect(RunLedger.inRepository(at: directory).failedRuns.records().count == 1)
        #expect(throws: ExitCode.failure) { try proved.run() }
    }
}

private extension RunProvedAfterQuietPassTests {
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
