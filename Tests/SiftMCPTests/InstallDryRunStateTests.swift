//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift install --dry-run` says what an install would do to each file as it stands: already installed where the install would change nothing, left alone where it would not touch what is there, not checked where only running the agent could say, and would write only where it would.
@Suite(.temporaryDirectories)
struct InstallDryRunStateTests {
    /// The line detection gives `target` when an install would write it.
    private static func wouldWrite(_ target: AgentDetection.Target) -> String {
        "    would write \(target.url.path) (\(target.what))"
    }

    /// The line a dry run gives `target` when an install would change nothing in it.
    private static func alreadyInstalled(_ target: AgentDetection.Target) -> String {
        "    already installed \(target.url.path) (\(target.what))"
    }

    /// Codex's `config.toml`, written as `codex mcp add` would leave it: the fake `codex` keeps its registration in memory.
    private static func writeCodexConfig(in machine: InstallCommandHarness) throws -> URL {
        let config = machine.home.appendingPathComponent(".codex/config.toml")
        try Data("[mcp_servers.sift]\ncommand = \"\(machine.binary)\"\nargs = [\"mcp\"]\n".utf8).write(to: config)
        return config
    }

    @Test
    func aDryRunAfterAnInstallSaysEveryFileItCanCheckIsAlreadyInstalled() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".cursor"])
        #expect(try machine.run(["--yes"]).status == 0)
        let config = try Self.writeCodexConfig(in: machine)
        let before = try machine.files()

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(try machine.files() == before)
        #expect(!run.printed.contains("would write"), "\(run.printed)")
        for target in AgentDetection.detect(machine.machine).findings.flatMap(\.targets) where target.url.path != config.path {
            #expect(run.lines.contains(Self.alreadyInstalled(target)), "\(target.url.path)")
        }
        #expect(run.lines.contains(
            "    not checked \(config.path) (the MCP server, through `codex mcp add`) — only `codex mcp get` can say whether sift is registered there"
        ))
        #expect(run.lines.contains("Claude Code MCP server: already registered"))
        #expect(run.lines.contains("Claude Code rule: already installed"))
    }

    @Test
    func aDryRunAfterInstallingOneAgentSaysItIsInstalledAndTheOthersWouldBeWritten() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".cursor"])
        #expect(try machine.run(["--agent", "cursor"]).status == 0)

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        let detection = AgentDetection.detect(machine.machine)
        for target in detection.finding(.cursor).targets {
            #expect(run.lines.contains(Self.alreadyInstalled(target)), "\(target.url.path)")
        }
        for target in detection.finding(.claude).targets + detection.finding(.codex).targets {
            #expect(run.lines.contains(Self.wouldWrite(target)), "\(target.url.path)")
        }
    }

    @Test
    func aForeignServerIsLeftAloneAndAForeignStatusLineGoesUnmentioned() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude", ".cursor"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        let mcp = machine.home.appendingPathComponent(".cursor/mcp.json")
        try Data(#"{"statusLine":{"type":"command","command":"/bin/other statusline"}}"#.utf8).write(to: settings)
        try Data(#"{"mcpServers":{"sift":{"command":"/bin/other","args":[]}}}"#.utf8).write(to: mcp)
        #expect(try machine.run(["--yes"]).status == 0)

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(run.lines.contains("    already installed \(settings.path) (hooks)"), "\(run.printed)")
        #expect(!run.printed.contains("status line"), "\(run.printed)")
        #expect(run.lines.contains { $0.hasPrefix("    left alone \(mcp.path) (the MCP server) — a server named sift runs something else (") }, "\(run.printed)")
    }

    /// A status line an older install registered is named on the settings line, because the install would take it out.
    @Test
    func aLegacyStatusLineIsNamedAsOneTheInstallRemoves() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude", ".cursor"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        #expect(try machine.run(["--yes"]).status == 0)
        let installed = try Data(contentsOf: settings)
        try LegacyStatusLine.adding(command: "/bin/sift statusline", to: installed).write(to: settings)

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(run.lines.contains("    would write \(settings.path) (hooks) — the status line an older install registered would be removed"), "\(run.printed)")
    }

    @Test
    func anUnreadableSettingsFileIsNamedAndTheDryRunStillAnswers() throws {
        let machine = try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".claude", ".cursor"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(run.lines.contains { $0.hasPrefix("    would be refused \(settings.path) (hooks) — could not be read") }, "\(run.printed)")
        #expect(run.lines.contains("dry run: nothing written and nothing run; without --dry-run this installs into Claude Code, Cursor, Codex"))
    }
}
