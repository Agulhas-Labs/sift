//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `sift run -- swift test` over a run that executed no test, in a package that declares test targets, exits ``RunTestSelector/exitCode`` and prints an inventory line; that it is no proof is pinned on ``RunOutcome/provedGreen(testBundles:selector:)`` in `RunUnfilteredZeroTestTests`, since this run reads the manifest and keys the tree from the test process's own checkout.
@Suite(.temporaryDirectories)
struct RunUnfilteredZeroExitTests {
    /// What a package whose one test target holds no test printed: XCTest's and Swift Testing's closing counts, both 0.
    private static var transcript: String {
        """
        Build complete! (4.46 secs)
        Test Suite 'All tests' started at 2026-10-02 06:49:41.667.
        Test Suite 'All tests' passed at 2026-10-02 06:49:41.668.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        \u{25C7} Test run started.
        \u{2714} Test run with 0 tests in 0 suites passed after 0.001 seconds.

        """
    }

    @Test
    func aRunThatExecutedNoTestExitsFourAndPrintsTheInventory() throws {
        let directory = try TemporaryDirectory.make("run-unfiltered-zero")
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Gadget", targets: [.target(name: "Gadget"), .testTarget(name: "GadgetTests", dependencies: ["Gadget"])])
        """.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let payload = bin.appendingPathComponent("transcript.txt")
        try Self.transcript.write(to: payload, atomically: true, encoding: .utf8)
        let swift = bin.appendingPathComponent("swift")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit 0\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "test"])
        command.log = RunUsageLog(fileURL: bin.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output

        #expect(throws: ExitCode(RunTestSelector.exitCode)) {
            try command.run()
        }
        #expect(recorded.printed.contains("nothing ran: no test executed"), "\(recorded.printed)")
        #expect(recorded.printed.contains("inventory: "), "\(recorded.printed)")
    }
}
