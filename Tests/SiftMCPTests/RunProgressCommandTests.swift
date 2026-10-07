//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the progress file a real `sift run` keeps in a git repository: ended by a signal, pruned, switched off, and never able to change what the run prints or how it exits.
@Suite(.temporaryDirectories)
struct RunProgressCommandTests {
    /// A `SIGTERM` to the run ends its file as `failed` with the shell's code for the signal, and the process still ends as a signalled one does, as it did before there was a file.
    @Test
    func aSignalEndsTheFileAsFailedAndTheProcessAsSignalled() throws {
        let fixture = try Fixture()
        let stop = fixture.root.appendingPathComponent("stop")
        // The child outlives the run it was started by, so it stops itself on a marker or after ten seconds.
        let script = "printf '[1/2] Compiling Gadget Gadget.swift\\n'; i=0; while [ $i -lt 100 ] && [ ! -e '\(stop.path)' ]; do sleep 0.1; i=$((i+1)); done"
        let process = try fixture.launch(["sh", "-c", script], progress: nil)
        defer { FileManager.default.createFile(atPath: stop.path, contents: nil) }

        let deadline = Date().addingTimeInterval(20)
        while fixture.snapshots().first?.phase != .building, Date() < deadline {
            usleep(50000)
        }
        #expect(fixture.snapshots().first?.phase == .building)
        kill(process.processIdentifier, SIGTERM)
        process.waitUntilExit()

        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
        let ended = try #require(fixture.snapshots().first)
        #expect(ended.phase == .failed)
        #expect(ended.exitCode == 128 + SIGTERM)
    }

    /// A progress directory nothing can be written into leaves the run's output and exit code exactly what they are with progress switched off, and holds no file afterwards.
    @Test
    func aFileThatCannotBeWrittenChangesNothingTheRunPrints() throws {
        let fixture = try Fixture()
        let directory = fixture.progressDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let command = ["sh", "-c", "printf '[1/2] Compiling Gadget Gadget.swift\\n'; printf 'oops\\n' >&2; exit 3"]

        let unwritable = try fixture.sift(command, progress: nil)
        let off = try fixture.sift(command, progress: "off")

        #expect(unwritable.status == 3)
        #expect(unwritable == off)
        #expect(fixture.snapshots().isEmpty)
    }

    /// `SIFT_PROGRESS=off` writes no progress directory at all.
    @Test
    func switchedOffARunWritesNothing() throws {
        let fixture = try Fixture()

        let finished = try fixture.sift(["sh", "-c", "exit 0"], progress: "off")

        #expect(finished.status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.progressDirectory.path))
    }

    /// Each run writes one file of its own, ended `done` with no build or test time when it did neither; the sixth run prunes the oldest, and git sees none of them.
    @Test
    func eachRunWritesOneFileAndTheSixthPrunesTheOldest() throws {
        let fixture = try Fixture()

        #expect(try fixture.sift(["sh", "-c", "exit 0"], progress: nil).status == 0)
        let first = fixture.snapshots()
        #expect(first.count == 1)
        #expect(first.first?.phase == .done && first.first?.exitCode == 0)
        #expect(first.first?.summary.map { $0.buildMs == nil && $0.testMs == nil } == true)
        for _ in 2 ... 6 {
            _ = try fixture.sift(["sh", "-c", "exit 0"], progress: nil)
        }

        let kept = fixture.snapshots()
        #expect(kept.count == RunProgressWriter.keptRuns)
        #expect(!kept.contains { $0.runId == first.first?.runId })
        #expect(try fixture.git(["status", "--porcelain", "--untracked-files=all"]).isEmpty)
    }

    /// A build writes the tree it started on into its file, the key the Stop gate matches a live run by.
    @Test
    func aBuildRecordsTheTreeItStartedOn() throws {
        let fixture = try Fixture()
        try "struct Gadget {}\n".write(to: fixture.repository.appendingPathComponent("Gadget.swift"), atomically: true, encoding: .utf8)
        let tree = try #require(TreeKey.of(repositoryRoot: fixture.repository)).value
        _ = try fixture.sift(["swift", "build"], progress: nil)

        #expect(fixture.snapshots().first?.tree == tree)
    }

    /// A command that neither builds nor tests has no tree to name.
    @Test
    func aCommandThatNeitherBuildsNorTestsRecordsNoTree() throws {
        let fixture = try Fixture()

        _ = try fixture.sift(["sh", "-c", "exit 0"], progress: nil)

        #expect(try #require(fixture.snapshots().first).tree == nil)
    }
}

private extension RunProgressCommandTests {
    struct Finished: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// A git repository with no commits, and a scratch home for everything `sift` keeps per user.
    struct Fixture {
        let root: URL
        let repository: URL
        let home: URL

        init() throws {
            root = try TemporaryDirectory.make("progress-command")
            repository = root.appendingPathComponent("repo")
            home = root.appendingPathComponent("home")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            _ = try git(["init", "-q"])
        }

        var progressDirectory: URL {
            RunProgressPaths.directory(in: repository, writesUnder: nil)
        }

        /// Every run file in the repository, newest first.
        func snapshots() -> [RunProgressSnapshot] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: progressDirectory.path)) ?? []
            return names.filter(RunProgressPaths.isRunFile).sorted(by: >).compactMap { name in
                (try? Data(contentsOf: progressDirectory.appendingPathComponent(name))).flatMap { try? RunProgressSnapshot.decoded(from: $0) }
            }
        }

        /// Starts `sift run -- <command>` with ``RunProgress/switchName`` set to `progress`, its output discarded.
        func launch(_ command: [String], progress: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> Process {
            let process = try process(command, progress: progress, sourceLocation: sourceLocation)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        /// Runs `sift run -- <command>` to its end.
        func sift(_ command: [String], progress: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> Finished {
            let process = try process(command, progress: progress, sourceLocation: sourceLocation)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let errors = ResultBox<Data>()
            let reader = Thread { errors.value = stderr.fileHandleForReading.readDataToEndOfFile() }
            reader.start()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            while errors.value == nil {
                usleep(10000)
            }
            return Finished(status: process.terminationStatus, stdout: String(data: out, encoding: .utf8) ?? "", stderr: String(data: errors.value ?? Data(), encoding: .utf8) ?? "")
        }

        private func process(_ command: [String], progress: String?, sourceLocation: SourceLocation) throws -> Process {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["run", "--"] + command
            process.currentDirectoryURL = repository
            var environment = ProcessEnvironment.withoutGit()
            environment["SIFT_HOME"] = home.path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            environment[RunProgress.switchName] = progress
            process.environment = environment
            return process
        }

        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repository
            process.environment = ProcessEnvironment.withoutGit()
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
