//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Runs the bundle's real `install.sh` against a fake bundle and a fake home, and reads back the deploy log it writes.
@Suite(.temporaryDirectories)
struct InstallScriptDeployLogTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Distribution/install.sh")

    /// A bundle holding the script, a fake `sift` that answers `--version` and ignores the rest, and a `BUILD_INFO`.
    private static func makeBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: script, to: bundle.appendingPathComponent("install.sh"))
        try "#!/bin/sh\n[ \"${1:-}\" = \"--version\" ] && echo 0.0.0-test\nexit 0\n"
            .write(to: bundle.appendingPathComponent("sift"), atomically: true, encoding: .utf8)
        try "rule\n".write(to: bundle.appendingPathComponent("Sift.md"), atomically: true, encoding: .utf8)
        try "version=0.0.0-test\ncommit=abc1234\ntree=clean\n"
            .write(to: bundle.appendingPathComponent("BUILD_INFO"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// Everything the script could write is under `directory`: `HOME`, the state directory and the destination are all temporary, no `GIT_*` variable is passed, and `PATH` holds no `claude`.
    private static func install(bundle: URL, in directory: URL, state: URL) throws -> Run {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let config = directory.appendingPathComponent("claude-config", isDirectory: true)
        let destination = directory.appendingPathComponent("dest", isDirectory: true)
        for folder in [home, config] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [bundle.appendingPathComponent("install.sh").path]
        process.environment = [
            "HOME": home.path,
            "SIFT_HOME": state.path,
            "SIFT_DEST": destination.path,
            "CLAUDE_CONFIG_DIR": config.path,
            "PATH": "/usr/bin:/bin",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            output: String(bytes: data, encoding: .utf8) ?? "",
            log: state.appendingPathComponent("deploys.jsonl")
        )
    }

    private static func rows(in log: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        }
    }

    /// One install leaves one parseable row naming the build, and a second install adds a second beneath it.
    @Test
    func eachInstallAppendsOneRow() throws {
        let directory = try TemporaryDirectory.make("install-script")
        let bundle = try Self.makeBundle(in: directory)
        let state = directory.appendingPathComponent("state", isDirectory: true)

        let first = try Self.install(bundle: bundle, in: directory, state: state)
        #expect(first.status == 0, "\(first.output)")
        let afterFirst = try Self.rows(in: first.log)
        #expect(afterFirst.count == 1)
        #expect(afterFirst.first?["commit"] as? String == "abc1234")
        #expect(afterFirst.first?["version"] as? String == "0.0.0-test")
        #expect(afterFirst.first?["tree"] as? String == "clean")
        #expect(afterFirst.first?["binarySize"] is Int)
        #expect(afterFirst.first?["ts"] is String)

        let second = try Self.install(bundle: bundle, in: directory, state: state)
        #expect(second.status == 0, "\(second.output)")
        #expect(try Self.rows(in: second.log).count == 2)
    }

    /// A state directory that cannot be written to is noted and never fails the install.
    @Test
    func anUnwritableStateDirectoryDoesNotFailTheInstall() throws {
        let directory = try TemporaryDirectory.make("install-script-readonly")
        let bundle = try Self.makeBundle(in: directory)
        let state = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state.path) }

        let run = try Self.install(bundle: bundle, in: directory, state: state)

        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("could not record this install"))
        #expect(!FileManager.default.fileExists(atPath: run.log.path))
    }
}

extension InstallScriptDeployLogTests {
    private struct Run {
        var status: Int32
        var output: String
        var log: URL
    }
}
