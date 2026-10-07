//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift install`'s summary and its failures: one agent failing leaves the others installed, the lines every installer repeats are said once, and `sift uninstall` afterwards leaves only what was there before.
@Suite(.temporaryDirectories)
struct InstallCommandSummaryTests {
    @Test
    func anUnreadableClaudeSettingsFileFailsClaudeAloneAndTheOthersAreInstalled() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude", ".cursor"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }

        let run = try machine.run(["--yes"])

        #expect(run.status == 1)
        #expect(run.lines.contains { $0.hasPrefix("  Claude Code: failed — claude: nothing written — \(settings.path) could not be read") })
        #expect(machine.claude.calls.isEmpty)
        #expect(machine.codex.server?.command == machine.binary)
        for file in [".cursor/mcp.json", ".cursor/hooks.json", ".codex/hooks.json"] {
            #expect(FileManager.default.fileExists(atPath: machine.home.appendingPathComponent(file).path), "\(file)")
        }
        #expect(run.lines.contains { $0.hasPrefix("  Cursor: installed — wrote ") })
        #expect(run.lines.contains { $0.hasPrefix("  Codex: installed — wrote ") })
    }

    @Test
    func eachUnsupportedAndExperimentalLineIsSaidOnceAndNoOneIsToldToTypeAHooksCommand() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".cursor"])

        let run = try machine.run(["--yes"])

        #expect(run.status == 0)
        for line in CursorInstall.unsupported + CodexInstall.unsupported + [CursorHookInstaller.experimental, CodexHookInstaller.experimental] {
            #expect(run.lines.count { $0.hasSuffix(line) } == 1, "\(line)")
        }
        for restart in [CursorHookInstaller.restart, CodexHookInstaller.restart] {
            #expect(!run.printed.contains(restart))
        }
        #expect(!run.printed.replacingOccurrences(of: "/hooks.json", with: "").contains("/hooks"))
        for agent in InstallAgent.allCases {
            #expect(run.lines.count { $0.hasSuffix("Next: \(InstallSummary.nextStep(agent)).") } == 1, "\(agent)")
        }
    }

    @Test
    func uninstallAfterInstallLeavesOnlyWhatWasThereBefore() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude/rules", ".cursor", ".codex"])
        let foreign: [String: String] = [
            ".claude/settings.json": #"{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/protect.sh"}]}]}}"#,
            ".claude.json": #"{"mcpServers":{"other":{"type":"stdio","command":"/bin/other","args":[]}}}"#,
            ".claude/rules/other.md": "kept",
            ".cursor/mcp.json": #"{"mcpServers":{"other":{"command":"/bin/other","args":[]}}}"#,
            ".cursor/hooks.json": #"{"version":1,"hooks":{"stop":[{"command":"~/protect.sh"}]}}"#,
            ".codex/hooks.json": #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/protect.sh"}]}]}}"#,
        ]
        for (path, text) in foreign {
            try text.write(to: machine.home.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        #expect(try machine.run(["--yes"]).status == 0)

        let recorded = RecordedOutput()
        var uninstall = try UninstallCommand.parse([])
        uninstall.environment = machine.environment
        uninstall.output = recorded.output
        uninstall.arguments = [machine.binary]
        let remover = UninstallCommandTests.ServerRemover()
        let config = machine.home.appendingPathComponent(".claude.json")
        uninstall.removeServer = { _, scope in remover.remove(from: config, scope: scope) }
        uninstall.codex = machine.codex
        try uninstall.run()

        #expect(machine.codex.server == nil)
        let live = try machine.files().filter { !$0.key.hasSuffix(".bak-sift") }
        #expect(Set(live.keys) == Set(foreign.keys))
        for (path, data) in live {
            let text = String(bytes: data, encoding: .utf8) ?? ""
            #expect(!text.contains(machine.bin.path), "\(path) still names the binary")
            #expect(text.contains("other") || text.contains("protect.sh") || text.contains("kept"), "\(path) lost its foreign content")
        }
    }
}
