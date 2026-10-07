//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A proof is keyed on what was tested, not on where SwiftPM built it, and a refusal names the proof that exists for another command.
@Suite(.temporaryDirectories)
struct ProvedBuildLocationKeyTests {
    @Test
    func buildLocationOptionsAreLeftOutOfTheKeyInBothSpellings() {
        #expect(ProofKey.command(of: ["swift", "test", "--scratch-path", "/x/y"]) == "swift test")
        #expect(ProofKey.command(of: ["swift", "test", "--build-path=/y"]) == "swift test")
        #expect(ProofKey.command(of: ["swift", "test", "--cache-path", "c", "--filter", "A"]) == "swift test --filter A")
        #expect(ProofKey.command(of: ["swift", "build", "--scratch-path=s", "-c", "release"]) == "swift build -c release")
    }

    @Test
    func everyOtherOptionAndOtherCommandsKeepTheirSpelling() {
        #expect(ProofKey.command(of: ["swift", "test", "--filter", "A"]) != ProofKey.command(of: ["swift", "test"]))
        #expect(ProofKey.command(of: ["swift", "test", "--skip", "A"]) == "swift test --skip A")
        #expect(ProofKey.command(of: ["swift", "test", "-Xswiftc", "-O"]) == "swift test -Xswiftc -O")
        #expect(ProofKey.command(of: ["xcodebuild", "test", "--scratch-path", "x"]) == "xcodebuild test --scratch-path x")
    }

    @Test
    func aGreenRunWithAScratchPathOrBuildPathProvesThePlainCommand() throws {
        let repository = try Self.repository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Self.seedGreen(command: ProofKey.command(of: ["swift", "test", "--scratch-path", "/tmp/a"]), in: repository)

        let plain = try Self.ask(["swift", "test"], in: repository)
        let other = try Self.ask(["swift", "test", "--build-path=/tmp/b"], in: repository)

        #expect(plain.status == 0, "\(plain.output)")
        #expect(other.status == 0, "\(other.output)")
    }

    @Test
    func aFilteredGreenDoesNotProveTheUnfilteredRunAndTheRefusalNamesIt() throws {
        let repository = try Self.repository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try Self.seedGreen(command: "swift test --filter X", in: repository)

        let asked = try Self.ask(["swift", "test"], in: repository)

        #expect(asked.status == 1)
        #expect(asked.output.contains("not proved: a green run exists for `swift test --filter X` (filtered); --proved checks `swift test`"), "\(asked.output)")
        #expect(!asked.output.contains("✔"), "\(asked.output)")
    }
}

private extension ProvedBuildLocationKeyTests {
    static func seedGreen(command: String, in repository: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let key = try #require(TreeKey.of(repositoryRoot: repository), sourceLocation: sourceLocation)
        let toolchain = try #require(ToolchainIdentity.current(), sourceLocation: sourceLocation)
        RunLedger.inRepository(at: repository).record(RunLedger.Record(
            tree: key.value,
            command: command,
            toolchain: toolchain.description,
            finishedAt: Date().addingTimeInterval(-60),
            log: nil,
            milliseconds: 1000,
            checkout: repository.path,
            workingDirectory: "."
        ))
    }

    static func ask(_ command: [String], in repository: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, output: String) {
        let sift = try #require(BuiltExecutable.sift, sourceLocation: sourceLocation)
        return try Self.run(sift.path, ["run", "--proved", "--"] + command, in: repository)
    }

    static func repository(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try TemporaryDirectory.make("proved-location-key").resolvingSymlinksInPath()
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
