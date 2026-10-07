//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// A Claude Code config that is there and cannot be read as a JSON object is refused and named, by the install and its dry run alike, never read as holding no server.
@Suite(.temporaryDirectories)
struct ClaudeMcpUnreadableConfigTests {
    private static var binary: String {
        "/opt/tools/bin/sift"
    }

    @Test
    func anInstallIntoAnUnparseableConfigRunsNothingAndSaysWhy() throws {
        let config = try TemporaryDirectory.make("claude-mcp").appendingPathComponent(".claude.json")
        try Data("not json {".utf8).write(to: config)
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls.isEmpty)
        #expect(outcome.failures.first?.hasPrefix("mcp: not registered — \(config.path) could not be read as a JSON object; repair it, then run: claude mcp add") == true, "\(outcome.failures)")
        #expect(outcome.written.isEmpty)
        #expect(try Data(contentsOf: config) == Data("not json {".utf8))
    }

    /// A config holding nothing but whitespace holds nothing to lose: it reads as absent, and the server is registered.
    @Test(arguments: ["", "  \n\t\r\n"])
    func aConfigHoldingOnlyWhitespaceIsReadAsAbsent(contents: String) throws {
        let config = try TemporaryDirectory.make("claude-mcp").appendingPathComponent(".claude.json")
        try Data(contents.utf8).write(to: config)
        let claude = FakeClaude(config: config)

        #expect(ClaudeMcpInstall.plan(config: config, binary: Self.binary) == .absent)
        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls == [ClaudeMcpInstall.addArguments(binary: Self.binary)])
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        #expect(outcome.written == [config.path])
    }

    /// Everything else that is there and is not a JSON object is still refused: a JSON array, a link to nothing, a directory, a file that cannot be opened.
    @Test(arguments: ["array", "dangling symlink", "directory", "unreadable mode"])
    func aConfigThatIsNotAnObjectIsStillRefused(shape: String) throws {
        let directory = try TemporaryDirectory.make("claude-mcp")
        let config = directory.appendingPathComponent(".claude.json")
        switch shape {
        case "array":
            try Data("[]".utf8).write(to: config)
        case "dangling symlink":
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: directory.appendingPathComponent("gone.json"))
        case "directory":
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
        default:
            try Data("{}".utf8).write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path) }
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls.isEmpty)
        #expect(outcome.failures.first?.hasPrefix("mcp: not registered — \(config.path) could not be read") == true, "\(outcome.failures)")
        #expect(outcome.written.isEmpty)
    }

    @Test
    func aDryRunSaysAnUnparseableConfigWouldBeRefusedNotWritten() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude", ".cursor"])
        let config = SiftPaths.claudeConfig(environment: machine.environment)
        try Data("not json {".utf8).write(to: config)
        let target = try #require(AgentDetection.detect(machine.machine).finding(.claude).targets.first { $0.url.path == config.path })

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(run.lines.contains("    would be refused \(config.path) (\(target.what)) — could not be read as a JSON object"), "\(run.printed)")
        #expect(!run.lines.contains("    would write \(config.path) (\(target.what))"))
        #expect(run.lines.contains("Claude Code MCP server: would be refused — \(config.path) could not be read as a JSON object"), "\(run.printed)")
    }
}
