//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// The Claude Code MCP registration `sift install` makes: decided from `.claude.json`, made through `claude mcp` with exact arguments, and never over a foreign server.
@Suite(.temporaryDirectories)
struct ClaudeMcpInstallTests {
    private static var binary: String {
        "/opt/tools/bin/sift"
    }

    private static func config(holding sift: [String: Any]?) throws -> URL {
        let config = try TemporaryDirectory.make("claude-mcp").appendingPathComponent(".claude.json")
        var servers: [String: Any] = ["other": ["type": "stdio", "command": "/bin/other", "args": []]]
        servers["sift"] = sift
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers, "theme": "dark"]).write(to: config)
        return config
    }

    @Test
    func anAbsentServerIsAddedAtUserScopeWithExactArgumentsAndReadBack() throws {
        let config = try Self.config(holding: nil)
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls == [["mcp", "add", "--transport", "stdio", "--scope", "user", "sift", "--", Self.binary, "mcp"]])
        #expect(outcome.lines == ["mcp: registered sift — \(Self.binary) mcp"])
        #expect(outcome.written == [config.path])
        #expect(outcome.failures.isEmpty)
        #expect(ClaudeMcpInstall.plan(config: config, binary: Self.binary) == .current)
    }

    @Test
    func aSecondRunRunsNothingAndSaysItIsThere() throws {
        let config = try Self.config(holding: ["type": "stdio", "command": Self.binary, "args": ["mcp"]])
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls.isEmpty)
        #expect(outcome.lines == ["mcp: already registered — \(Self.binary) mcp"])
        #expect(!outcome.changed)
    }

    @Test
    func aForeignServerNamedSiftIsLeftAloneAndNamed() throws {
        let config = try Self.config(holding: ["type": "stdio", "command": "/opt/other/server", "args": ["serve"]])
        let before = try Data(contentsOf: config)
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls.isEmpty)
        #expect(outcome.lines == ["mcp: left alone — a server named sift runs something else (/opt/other/server serve)"])
        #expect(outcome.failures.isEmpty)
        #expect(try Data(contentsOf: config) == before)
    }

    @Test
    func oursAtAnotherPathIsRemovedThenAdded() throws {
        let config = try Self.config(holding: ["type": "stdio", "command": "/old/bin/sift", "args": ["mcp"]])
        let claude = FakeClaude(config: config)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: Self.binary, runner: claude)

        #expect(claude.calls == [
            ["mcp", "remove", "sift", "--scope", "user"],
            ["mcp", "add", "--transport", "stdio", "--scope", "user", "sift", "--", Self.binary, "mcp"],
        ])
        #expect(outcome.lines == ["mcp: replaced stale registration (/old/bin/sift mcp)", "mcp: registered sift — \(Self.binary) mcp"])
    }

    @Test
    func withoutClaudeTheManualLineIsPrintedAndNothingFails() throws {
        let config = try Self.config(holding: nil)
        let claude = FakeClaude(config: config, present: false)

        let outcome = try ClaudeMcpInstall.install(config: config, binary: "/opt/my tools/sift", runner: claude)

        #expect(outcome.lines == ["mcp: `claude` is not on PATH — register the server with: claude mcp add --transport stdio --scope user sift -- '/opt/my tools/sift' mcp"])
        #expect(outcome.failures.isEmpty)
        #expect(!outcome.changed)
    }

    @Test
    func aFailedAddOrOneTheConfigDoesNotShowIsAFailure() throws {
        let refused = try Self.config(holding: nil)
        let failing = try ClaudeMcpInstall.install(config: refused, binary: Self.binary, runner: FakeClaude(config: refused, addSucceeds: false))
        #expect(failing.failures.first?.hasPrefix("mcp: not registered — `claude mcp add` failed: add refused; run: claude mcp add") == true)

        let silent = try Self.config(holding: nil)
        let unconfirmed = try ClaudeMcpInstall.install(config: silent, binary: Self.binary, runner: FakeClaude(config: silent, addWrites: false))
        #expect(unconfirmed.failures.first?.hasPrefix("mcp: not registered — `claude mcp add` succeeded but \(silent.path) does not name") == true)
        #expect(unconfirmed.written.isEmpty)
    }

    @Test
    func theConfigAndTheRuleFollowClaudeConfigDir() {
        let moved = ["HOME": "/scratch/home", "CLAUDE_CONFIG_DIR": "/scratch/claude"]
        #expect(SiftPaths.claudeConfig(environment: moved).path == "/scratch/claude/.claude.json")
        #expect(SiftPaths.claudeRule(environment: moved).path == "/scratch/claude/rules/sift.md")
        let plain = ["HOME": "/scratch/home"]
        #expect(SiftPaths.claudeConfig(environment: plain).path == "/scratch/home/.claude.json")
        #expect(SiftPaths.claudeRule(environment: plain).path == "/scratch/home/.claude/rules/sift.md")
    }
}
