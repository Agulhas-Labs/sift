//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// What `sift install` detects: each sign of each agent present and absent, on a scratch machine whose PATH, home and applications directory are all temporary, so no test ever sees the real `claude`, `codex`, `agent` or `/Applications`.
@Suite(.temporaryDirectories)
struct AgentDetectionTests {
    @Test
    func anEmptyMachineHasNothingDetected() throws {
        let scratch = try Scratch()

        let detection = scratch.detect()

        #expect(detection.detected.isEmpty)
        #expect(detection.findings.map(\.agent) == InstallAgent.allCases)
        #expect(detection.finding(.claude).lookedFor == ["`claude` on PATH", "~/.claude"])
        #expect(detection.finding(.cursor).lookedFor == ["~/.cursor", "\(scratch.applications.path)/Cursor.app", "`agent` on PATH", "`cursor-agent` on PATH"])
        #expect(detection.finding(.codex).lookedFor == ["`codex` on PATH", "~/.codex"])
    }

    @Test
    func claudeIsFoundOnThePath() throws {
        let scratch = try Scratch()
        try scratch.executable("claude")

        #expect(scratch.detect().detected == [.claude])
        #expect(scratch.detect().finding(.claude).reason == "`claude` on PATH")
    }

    @Test
    func claudeIsFoundByItsDirectory() throws {
        let scratch = try Scratch()
        try scratch.directory(scratch.home.appendingPathComponent(".claude"))

        #expect(scratch.detect().detected == [.claude])
        #expect(scratch.detect().finding(.claude).reason == "~/.claude exists")
    }

    @Test
    func aDirectoryNamedClaudeOnThePathIsNotTheBinary() throws {
        let scratch = try Scratch()
        try scratch.directory(scratch.bin.appendingPathComponent("claude"))

        #expect(scratch.detect().detected.isEmpty)
    }

    @Test
    func claudeConfigDirMovesTheDirectoryLookedFor() throws {
        var scratch = try Scratch()
        let config = scratch.root.appendingPathComponent("claude-config", isDirectory: true)
        scratch.environment["CLAUDE_CONFIG_DIR"] = config.path
        try scratch.directory(scratch.home.appendingPathComponent(".claude"))

        #expect(scratch.detect().detected.isEmpty)

        try scratch.directory(config)
        let finding = scratch.detect().finding(.claude)
        #expect(finding.reason == "$CLAUDE_CONFIG_DIR (\(config.path)) exists")
        #expect(finding.targets.map(\.url.path) == [
            config.appendingPathComponent("settings.json").path,
            config.appendingPathComponent(".claude.json").path,
            config.appendingPathComponent("rules/sift.md").path,
        ])
    }

    @Test(arguments: ["cursor directory", "Cursor.app", "agent", "cursor-agent"])
    func cursorIsFoundByEachSign(_ sign: String) throws {
        let scratch = try Scratch()
        let expected: String
        switch sign {
        case "cursor directory":
            try scratch.directory(scratch.home.appendingPathComponent(".cursor"))
            expected = "~/.cursor exists"
        case "Cursor.app":
            try scratch.directory(scratch.applications.appendingPathComponent("Cursor.app"))
            expected = "\(scratch.applications.path)/Cursor.app exists"
        default:
            try scratch.executable(sign)
            expected = "`\(sign)` on PATH"
        }

        let detection = scratch.detect()

        #expect(detection.detected == [.cursor])
        #expect(detection.finding(.cursor).reason == expected)
    }

    @Test
    func codexIsFoundOnThePath() throws {
        let scratch = try Scratch()
        try scratch.executable("codex")

        #expect(scratch.detect().detected == [.codex])
        #expect(scratch.detect().finding(.codex).reason == "`codex` on PATH")
    }

    @Test
    func codexIsFoundByItsHome() throws {
        let scratch = try Scratch()
        try scratch.directory(scratch.home.appendingPathComponent(".codex"))

        #expect(scratch.detect().detected == [.codex])
        #expect(scratch.detect().finding(.codex).reason == "~/.codex exists")
    }

    @Test
    func codexHomeMovesTheHomeLookedForAndWrittenTo() throws {
        var scratch = try Scratch()
        let codexHome = scratch.root.appendingPathComponent("codex-home", isDirectory: true)
        scratch.environment["CODEX_HOME"] = codexHome.path
        try scratch.directory(scratch.home.appendingPathComponent(".codex"))

        #expect(scratch.detect().detected.isEmpty)

        try scratch.directory(codexHome)
        let detection = scratch.detect()
        #expect(detection.finding(.codex).reason == "$CODEX_HOME (\(codexHome.path)) exists")
        #expect(detection.text.contains("    would write \(codexHome.path)/hooks.json (hooks, in the Codex home from $CODEX_HOME)"))
        #expect(detection.text.contains("    would write \(codexHome.path)/config.toml (the MCP server, through `codex mcp add`)"))
    }

    @Test
    func theInjectedSeamsAreTheOnlyThingsRead() {
        let machine = AgentDetection.Machine(
            environment: ["HOME": "/scratch/home", "PATH": "/scratch/bin"],
            applications: URL(fileURLWithPath: "/scratch/Applications", isDirectory: true),
            pathLookup: { $0 == "cursor-agent" ? URL(fileURLWithPath: "/scratch/bin/cursor-agent") : nil },
            fileExists: { $0.path == "/scratch/home/.codex" }
        )

        let detection = AgentDetection.detect(machine)

        #expect(detection.detected == [.cursor, .codex])
        #expect(detection.finding(.cursor).reason == "`cursor-agent` on PATH")
        #expect(detection.finding(.codex).reason == "~/.codex exists")
    }

    @Test
    func theTextNamesEachAgentAndEveryFileItWouldWrite() throws {
        let scratch = try Scratch()
        try scratch.executable("claude")
        let home = scratch.home.path

        #expect(scratch.detect().text == """
        Claude Code: found — `claude` on PATH
            would write \(home)/.claude/settings.json (hooks)
            would write \(home)/.claude.json (the MCP server at user scope, through `claude mcp add`)
            would write \(home)/.claude/rules/sift.md (the agent rule)
        Cursor: not found — looked for ~/.cursor, \(scratch.applications.path)/Cursor.app, `agent` on PATH, `cursor-agent` on PATH
            would write \(home)/.cursor/mcp.json (the MCP server)
            would write \(home)/.cursor/hooks.json (hooks)
        Codex: not found — looked for `codex` on PATH, ~/.codex
            would write \(home)/.codex/hooks.json (hooks, in the Codex home from ~/.codex)
            would write \(home)/.codex/config.toml (the MCP server, through `codex mcp add`)
        """)
    }
}

extension AgentDetectionTests {
    /// A scratch machine: an empty home, an empty PATH directory and an empty applications directory.
    private struct Scratch {
        let home: URL
        let bin: URL
        let applications: URL
        let root: URL
        var environment: [String: String]

        init() throws {
            root = try TemporaryDirectory.make("agent-detection")
            home = root.appendingPathComponent("home", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            applications = root.appendingPathComponent("Applications", isDirectory: true)
            for directory in [home, bin, applications] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            environment = ["HOME": home.path, "PATH": bin.path]
        }

        func executable(_ name: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func directory(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func detect() -> AgentDetection {
            AgentDetection.detect(AgentDetection.Machine(environment: environment, applications: applications))
        }
    }
}
