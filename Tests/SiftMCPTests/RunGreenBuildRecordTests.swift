//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// What a plain `sift run` build files for the stop gate, which reads it where a transcript cannot tell whether the run was green.
@Suite(.temporaryDirectories)
struct RunGreenBuildRecordTests {
    /// A green build records the tree it saw in the checkout's green-build file under ``RunCommand/writesUnder``, for the stop gate to find however the shell around the run was written, and a failed one records nothing.
    ///
    /// None of it reaches the proved ledger, and none of it this checkout's own file.
    @Test(arguments: [(Int32(0), 1), (Int32(1), 0)])
    func aGreenBuildRecordsItsTreeForTheStopGateAndAFailedOneNothing(exitCode: Int32, recorded: Int) throws {
        let root = try #require(GitContext.discoverRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let directory = try TemporaryDirectory.make("run-command-green-build")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\necho '\(exitCode == 0 ? "Build complete!" : "error: no such module Gone")'\nexit \(exitCode)\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        if exitCode == 0 {
            try command.run()
        } else {
            #expect(throws: ExitCode(exitCode)) { try command.run() }
        }
        let builds = RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json")).records()
        let checkoutBuilds = RunLedger(fileURL: SiftPaths.cache(in: root).appendingPathComponent("green-builds.json")).records()

        #expect(builds.count == recorded)
        #expect(builds.allSatisfy { $0.checkout == root.path && $0.command == "\(swift.path) build" && $0.workingDirectory == "." })
        #expect(!checkoutBuilds.contains { $0.command.contains(directory.path) })
        #expect(RunLedger.inRepository(at: directory).records().isEmpty)
    }

    /// A build pointed at another checkout — `--package-path` or `-C` — records that checkout's tree, for that checkout, and nothing for the one `sift run` was started in: a green build of a sibling package says nothing about a launching package that does not compile.
    @Test(arguments: ["--package-path", "-C"])
    func aBuildOfAnotherCheckoutRecordsThatCheckoutAndNotTheLaunchingOne(flag: String) throws {
        let root = try #require(GitContext.discoverRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let directory = try TemporaryDirectory.make("run-command-green-build-elsewhere")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-command-green-build-built")
        defer { try? FileManager.default.removeItem(at: built) }
        let builtRoot = try #require(GitContext.discoverRoot(from: built))
        let command = try Self.build(flag, built, in: directory, script: "echo 'Build complete!'")

        try command.run()
        let builds = RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json")).records()

        #expect(builds.map(\.checkout) == [builtRoot.path])
        #expect(try builds.map(\.tree) == [#require(TreeKey.of(repositoryRoot: builtRoot)).value])
        #expect(!builds.contains { $0.checkout == root.path })
    }

    /// A proved test run of another checkout — an `xcodebuild -project` inside it — files its proof for that checkout's tree, and `--proved` of the same command asks that checkout, so the two agree.
    @Test
    func aProvedRunOfAnotherCheckoutFilesItsProofForThatCheckout() throws {
        let directory = try TemporaryDirectory.make("run-command-proof-elsewhere")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-command-proof-built")
        defer { try? FileManager.default.removeItem(at: built) }
        let builtRoot = try #require(GitContext.discoverRoot(from: built))
        let xcodebuild = directory.appendingPathComponent("xcodebuild")
        try """
        #!/bin/sh
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' started."
        echo "Test Case '-[ProofUITests.ProofTests testProvedElsewhere]' passed (0.1 seconds)."
        echo '** TEST SUCCEEDED **'
        exit 0

        """.write(to: xcodebuild, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        let arguments = ["--", xcodebuild.path, "-project", built.appendingPathComponent("Demo.xcodeproj").path, "-scheme", "Demo", "test"]
        var command = try RunCommand.parse(arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        var proved = try RunCommand.parse(["--proved"] + arguments)
        proved.writesUnder = directory

        try command.run()
        let proofs = RunLedger.inRepository(at: directory).records()

        #expect(proofs.map(\.checkout) == [builtRoot.path])
        #expect(try proofs.map(\.tree) == [#require(TreeKey.of(repositoryRoot: builtRoot)).value])
        #expect(throws: ExitCode.success) { try proved.run() }
    }

    /// A tree edited while the build ran records nothing: the build read neither the tree before it nor the one after it whole, so a record of either would stand for something never built.
    @Test
    func aTreeEditedWhileTheBuildRanRecordsNothing() throws {
        let directory = try TemporaryDirectory.make("run-command-green-build-moving")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.gitRepository("run-command-green-build-moved")
        defer { try? FileManager.default.removeItem(at: built) }
        let command = try Self.build("--package-path", built, in: directory, script: "echo edited > '\(built.path)/Edited.swift'\necho 'Build complete!'")

        try command.run()

        #expect(RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json")).records().isEmpty)
    }

    /// A green run that skips the build compiled nothing, so it records no green build; a plain `swift test` still does.
    @Test(arguments: [
        ("swift", ["test", "--skip-build"], 0),
        ("swift", ["test", "--skip-build", "--filter", "X"], 0),
        ("xcodebuild", ["test-without-building", "-scheme", "App"], 0),
        ("swift", ["test"], 1),
        ("xcodebuild", ["test", "-scheme", "App"], 1),
    ])
    func aRunThatSkipsTheBuildRecordsNoGreenBuild(tool: String, flags: [String], recorded: Int) throws {
        let directory = try TemporaryDirectory.make("run-command-green-build-skip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent(tool)
        try "#!/bin/sh\necho 'Test run with 1 test in 1 suite passed'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var command = try RunCommand.parse(["--", script.path] + flags)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory

        try command.run()

        #expect(RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json")).records().count == recorded)
    }

    /// A build pointed at a directory in no repository records nothing: there is no checkout it built to record it for.
    @Test
    func aBuildOfADirectoryInNoRepositoryRecordsNothing() throws {
        let directory = try TemporaryDirectory.make("run-command-green-build-nowhere")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = try Self.build("--package-path", directory, in: directory, script: "echo 'Build complete!'")

        try command.run()

        #expect(RunLedger(fileURL: SiftPaths.cache(in: directory).appendingPathComponent("green-builds.json")).records().isEmpty)
    }
}

private extension RunGreenBuildRecordTests {
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

    /// A `sift run` of a stand-in `swift build` pointed at `built` by `flag`, running `script` and exiting 0, with every write scoped under `directory`.
    static func build(_ flag: String, _ built: URL, in directory: URL, script: String) throws -> RunCommand {
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\n\(script)\nexit 0\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var command = try RunCommand.parse(["--", swift.path, "build", flag, built.path])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        return command
    }
}
