//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift run --proved` on a tree the ledger has no record of says what moved since the last green run of the same command, so a gate that refused on it names the edit made after the run.
///
/// Drives the built binary in a fixture repository, since the question is answered about the working directory's repository and a test cannot move the process's own.
@Suite(.temporaryDirectories)
struct ProvedRunExplanationTests {
    /// A tree edited after its green run is not proved, and the answer names the file the edit touched and how long ago the run was.
    @Test
    func aTreeEditedAfterItsGreenRunNamesTheFileThatMoved() throws {
        let repository = try Self.repository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let key = try #require(TreeKey.of(repositoryRoot: repository))
        let toolchain = try #require(ToolchainIdentity.current())
        RunLedger.inRepository(at: repository).record(RunLedger.Record(
            tree: key.value,
            command: "swift test",
            toolchain: toolchain.description,
            finishedAt: Date().addingTimeInterval(-360),
            log: nil,
            milliseconds: 1000,
            checkout: repository.path,
            workingDirectory: "."
        ))
        try "struct Gizmo { let size = 1 }\n".write(to: repository.appendingPathComponent("Sources/Gizmo.swift"), atomically: true, encoding: .utf8)

        let asked = try Self.askProved(in: repository)

        #expect(asked.status == 1)
        #expect(asked.output.contains("last green run 6m ago on a tree that differs in 1 file: Sources/Gizmo.swift"), "\(asked.output)")
    }

    /// A repository where the command has never passed says so, rather than exiting 1 with nothing to act on.
    @Test
    func aRepositoryWithNoGreenRunSaysSo() throws {
        let repository = try Self.repository()
        defer { try? FileManager.default.removeItem(at: repository) }

        let asked = try Self.askProved(in: repository)

        #expect(asked.status == 1)
        #expect(asked.output.contains("no green run of swift test recorded on this repository"), "\(asked.output)")
    }
}

private extension ProvedRunExplanationTests {
    /// A committed repository holding one Swift file.
    static func repository(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try TemporaryDirectory.make("proved-explanation").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "struct Gizmo {}\n".write(to: root.appendingPathComponent("Sources/Gizmo.swift"), atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Tester"],
            ["add", "-A"],
            ["commit", "-q", "-m", "seed"],
        ] {
            #expect(try run("/usr/bin/git", arguments, in: root).status == 0, sourceLocation: sourceLocation)
        }
        return root
    }

    /// Runs this build's `sift run --proved -- swift test` in `repository`.
    static func askProved(in repository: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, output: String) {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        return try run(sift.path, ["run", "--proved", "--", "swift", "test"], in: repository)
    }

    /// One process in `directory`, with no git variables and the ledger switched on, reporting its exit status and everything it printed.
    static func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessEnvironment.withoutGit()
        environment[RunLedger.switchName] = nil
        process.environment = environment
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    }
}
