//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Claude Code reads `settings.json` from `CLAUDE_CONFIG_DIR` when it is set, so the hooks `install-hook` writes, the ones `uninstall-hook` takes out and the file `uninstall` cleans all have to be that file, never the `~/.claude` one.
@Suite(.temporaryDirectories)
struct ClaudeConfigDirSettingsTests {
    private static func installCommand(_ scratch: Scratch) throws -> InstallHookCommand {
        var command = try InstallHookCommand.parse(["--no-allow-run"])
        command.output = RecordedOutput().output
        command.environment = scratch.environment
        command.arguments = ["/bin/sift"]
        return command
    }

    @Test
    func theSettingsPathFollowsClaudeConfigDir() throws {
        let scratch = try Scratch()

        #expect(SiftPaths.claudeSettings(environment: scratch.environment).path == scratch.moved.path)
        #expect(SiftPaths.claudeSettings(environment: ["CFFIXED_USER_HOME": scratch.home.path]).path == scratch.inHome.path)
        #expect(SiftPaths.claudeSettings(environment: ["CFFIXED_USER_HOME": scratch.home.path, "CLAUDE_CONFIG_DIR": ""]).path == scratch.inHome.path)
    }

    @Test
    func installHookWritesTheSettingsInClaudeConfigDir() throws {
        let scratch = try Scratch()
        let command = try Self.installCommand(scratch)
        try command.run()

        #expect(FileManager.default.fileExists(atPath: scratch.moved.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.inHome.path))
    }

    @Test
    func uninstallHookTakesTheHooksOutOfClaudeConfigDir() throws {
        let scratch = try Scratch()
        let install = try Self.installCommand(scratch)
        try install.run()
        #expect(try String(contentsOf: scratch.moved, encoding: .utf8).contains("session-start"))

        var uninstall = try UninstallHookCommand.parse([])
        uninstall.output = RecordedOutput().output
        uninstall.environment = scratch.environment
        try uninstall.run()

        #expect(try !String(contentsOf: scratch.moved, encoding: .utf8).contains("session-start"))
        #expect(!FileManager.default.fileExists(atPath: scratch.inHome.path))
    }

    @Test
    func uninstallCleansTheSettingsInClaudeConfigDir() throws {
        let scratch = try Scratch()
        let usageLog = scratch.home.appendingPathComponent("usage.jsonl")

        let locations = SiftUninstall.Locations.standard(environment: scratch.environment, usageLog: usageLog)

        #expect(locations.settings.path == scratch.moved.path)
    }
}

extension ClaudeConfigDirSettingsTests {
    /// A scratch home and a config directory beside it, with the environment that names both.
    struct Scratch {
        let home: URL
        let config: URL
        let environment: [String: String]

        init() throws {
            let root = try TemporaryDirectory.make("claude-config-dir")
            home = root.appendingPathComponent("home", isDirectory: true)
            config = root.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            environment = ["CFFIXED_USER_HOME": home.path, "CLAUDE_CONFIG_DIR": config.path]
        }

        var moved: URL {
            config.appendingPathComponent("settings.json")
        }

        var inHome: URL {
            home.appendingPathComponent(".claude/settings.json")
        }
    }
}
