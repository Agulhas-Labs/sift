//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A lookup run from a shell that cannot write the usage log: an agent's sandbox lets a command write its working tree and the temporary directories, and `~/.sift` is neither.
///
/// Driven through the built binary, since the claim is about a process: its output is the answer and nothing else, whatever happened to the log. The log's directory is stood in for by a regular file of that name, which no process can create a file under.
@Suite(.temporaryDirectories)
struct CLIUsageLogSilenceTests {
    /// The answer is byte for byte the one a writable log gets, and nothing is said about the log.
    @Test
    func aLookupWhoseLogCannotBeWrittenPrintsTheAnswerAndNothingElse() async throws {
        let repo = try await InPlaceAnswerTests.indexedRepository()
        let scratch = try TemporaryDirectory.make("usage-silence").appendingPathComponent("usage-silence")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let blocked = scratch.appendingPathComponent("blocked")
        try Data().write(to: blocked)

        let answered = try Self.run(["digest", "Sources/App/Depot.swift", "--root", repo.path], home: scratch, log: scratch.appendingPathComponent("writable/usage.jsonl"))
        let sandboxed = try Self.run(["digest", "Sources/App/Depot.swift", "--root", repo.path], home: scratch, log: blocked.appendingPathComponent("usage.jsonl"))

        #expect(answered.status == 0)
        #expect(sandboxed.status == 0)
        #expect(sandboxed.stderr.isEmpty, "a write to the usage log failing reached the answer stream: \(sandboxed.stderr)")
        #expect(sandboxed.stdout == answered.stdout)
        #expect(answered.stderr.isEmpty)
        #expect(!answered.stdout.isEmpty)
    }
}

private extension CLIUsageLogSilenceTests {
    struct Ran {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ arguments: [String], home: URL, log: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Ran {
        let binary = try #require(
            BuiltExecutable.sift,
            "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
            sourceLocation: sourceLocation
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["HOME"] = home.path
        environment["SIFT_USAGE_LOG"] = log.path
        environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try Ran(
            status: process.terminationStatus,
            stdout: #require(String(bytes: printed, encoding: .utf8), sourceLocation: sourceLocation),
            stderr: #require(String(bytes: said, encoding: .utf8), sourceLocation: sourceLocation)
        )
    }
}
