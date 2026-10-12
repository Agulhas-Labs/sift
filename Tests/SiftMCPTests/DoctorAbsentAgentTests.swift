//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift doctor` on a machine where only Claude Code is found: the other agents are named and skipped, unless `--agent` asks for them.
@Suite(.temporaryDirectories)
struct DoctorAbsentAgentTests {
    @Test
    func absentAgentsAreSkippedAndTheFoundOneDecidesTheExit() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: false))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("cursor: not detected, skipped"), "\(run.printed)")
        #expect(run.printed.contains("codex: not detected, skipped"), "\(run.printed)")
        #expect(!run.printed.contains("cursor hooks"), "\(run.printed)")
        #expect(run.printed.contains("claude hooks: pass"), "\(run.printed)")
    }

    @Test
    func aFoundAgentWithNothingOfSiftIsNamedAndNeverFails() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: true))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("cursor: found, sift not installed — sift install --agent cursor adds it"), "\(run.printed)")
        #expect(!run.printed.contains("cursor hooks"), "\(run.printed)")
        #expect(run.printed.contains("codex: not detected, skipped"), "\(run.printed)")
    }

    @Test
    func aFoundAgentWithSomeOfSiftStillFails() throws {
        let machine = try Self.machine(cursorDirectory: true)
        let home = try URL(fileURLWithPath: #require(machine.environment["HOME"]))
        let binary = try #require(BuiltExecutable.sift).path
        let config: [String: Any] = ["mcpServers": ["sift": ["command": binary, "args": ["mcp"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".cursor/mcp.json"))
        let run = try Self.doctor(machine)

        #expect(run.status == 1, "\(run.printed)")
        #expect(run.printed.contains("cursor hooks: fail"), "\(run.printed)")
        #expect(!run.printed.contains("sift not installed"), "\(run.printed)")
    }

    @Test
    func anAgentNamedIsCheckedWhereItWasNotFound() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: false), ["--agent", "cursor"])

        #expect(run.status == 1, "\(run.printed)")
        #expect(run.printed.contains("cursor hooks: fail"), "\(run.printed)")
        #expect(!run.printed.contains("not detected, skipped"), "\(run.printed)")
    }

    @Test
    func whenEveryFoundAgentHasNoSiftTheVerdictSaysSoAndExitsNonZero() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: true, claudeInstalled: false))

        #expect(run.status == 1, "\(run.printed)")
        #expect(run.printed.contains("doctor: failed — no agent has sift installed; `sift install` adds it"), "\(run.printed)")
        #expect(!run.printed.contains("0 of 0 checks"), "\(run.printed)")
        #expect(run.printed.contains("claude: found, sift not installed"), "\(run.printed)")
        #expect(run.printed.contains("cursor: found, sift not installed"), "\(run.printed)")
    }

    @Test
    func claudeWithNothingOfSiftHasNothing() throws {
        let home = try Self.bareHome()

        #expect(try Self.claude(home).hasNothingOfSift)
    }

    @Test
    func claudeWithAnUnreadableServerFileHasSomething() throws {
        let home = try Self.bareHome()
        let file = home.appendingPathComponent(".claude.json")
        try Self.write(["mcpServers": ["sift": ["command": "/x/sift", "args": ["mcp"]]]], to: file)
        try Self.unreadable(file)
        defer { Self.restore(file) }

        #expect(try !Self.claude(home).hasNothingOfSift)
    }

    @Test
    func claudeWithAServerNamedSiftThatIsNotOursHasSomething() throws {
        let home = try Self.bareHome()
        try Self.write(["mcpServers": ["sift": ["command": "npx", "args": ["-y", "@agulhas-labs/sift", "mcp"]]]], to: home.appendingPathComponent(".claude.json"))

        #expect(try !Self.claude(home).hasNothingOfSift)
    }

    @Test
    func claudeWithMalformedSettingsHasSomething() throws {
        let home = try Self.bareHome()
        try Data("{ not json".utf8).write(to: home.appendingPathComponent(".claude/settings.json"))

        #expect(try !Self.claude(home).hasNothingOfSift)
    }

    @Test
    func cursorWithAnUnreadableServerFileHasSomething() throws {
        let directory = try Self.scratchDirectory()
        let file = directory.appendingPathComponent("mcp.json")
        try Self.write(["mcpServers": ["sift": ["command": "/x/sift", "args": ["mcp"]]]], to: file)
        try Self.unreadable(file)
        defer { Self.restore(file) }

        #expect(try !Self.cursor(directory).hasNothingOfSift)
    }

    @Test
    func cursorWithMalformedHooksMentioningSiftHasSomething() throws {
        let directory = try Self.scratchDirectory()
        try Data("{\"hooks\": {\"sessionStart\": [{\"command\": \"/x/sift hook\"}]".utf8).write(to: directory.appendingPathComponent("hooks.json"))

        #expect(try !Self.cursor(directory).hasNothingOfSift)
    }

    @Test
    func cursorWithAForeignHookMentioningSiftHasSomething() throws {
        let directory = try Self.scratchDirectory()
        try Self.write(["version": 1, "hooks": ["sessionStart": [["command": "npx -y @agulhas-labs/sift session-start"]]]], to: directory.appendingPathComponent("hooks.json"))

        #expect(try !Self.cursor(directory).hasNothingOfSift)
    }

    @Test(arguments: [["-y", "@agulhas-labs/sift", "mcp"], ["mcp", "--root", "/x"]])
    func cursorWithAServerNamedSiftThatIsNotOursHasSomething(arguments: [String]) throws {
        let directory = try Self.scratchDirectory()
        let command = arguments.first == "-y" ? "npx" : "/x/sift"
        try Self.write(["mcpServers": ["sift": ["command": command, "args": arguments]]], to: directory.appendingPathComponent("mcp.json"))

        #expect(try !Self.cursor(directory).hasNothingOfSift)
    }

    @Test
    func cursorWithAServerOfOursUnderAnotherNameHasSomething() throws {
        let directory = try Self.scratchDirectory()
        try Self.write(["mcpServers": ["code-index": ["command": "/x/sift", "args": ["mcp"]]]], to: directory.appendingPathComponent("mcp.json"))

        #expect(try !Self.cursor(directory).hasNothingOfSift)
    }

    @Test
    func cursorWithOnlyOtherServersHasNothing() throws {
        let directory = try Self.scratchDirectory()
        try Self.write(["mcpServers": ["other": ["command": "/x/other", "args": ["serve"]]]], to: directory.appendingPathComponent("mcp.json"))

        #expect(try Self.cursor(directory).hasNothingOfSift)
    }

    @Test
    func codexWithNothingOfSiftHasNothing() throws {
        let directory = try Self.scratchDirectory()

        #expect(try Self.codex(directory, FakeCodex()).hasNothingOfSift)
    }

    @Test
    func codexWithAServerNamedSiftHasSomething() throws {
        let directory = try Self.scratchDirectory()

        #expect(try !Self.codex(directory, FakeCodex(server: ("/x/sift", ["mcp"]))).hasNothingOfSift)
        #expect(try !Self.codex(directory, FakeCodex(server: ("npx", ["-y", "@agulhas-labs/sift", "mcp"]))).hasNothingOfSift)
    }

    @Test
    func codexThatCannotAnswerHasSomething() throws {
        let directory = try Self.scratchDirectory()

        #expect(try !Self.codex(directory, FakeCodex(getError: "Error: failed to parse config.toml")).hasNothingOfSift)
        #expect(try !Self.codex(directory, FakeCodex(present: false)).hasNothingOfSift)
    }

    @Test
    func codexWhoseHomeDoesNotExistHasNothingWithoutAskingCodex() throws {
        let missing = try Self.scratchDirectory().appendingPathComponent("no-such-codex-home", isDirectory: true)

        #expect(try Self.codex(missing, FakeCodex(getError: "Error: CODEX_HOME points to a path that does not exist")).hasNothingOfSift)
        #expect(try Self.codex(missing, FakeCodex(present: false)).hasNothingOfSift)
    }

    @Test
    func codexWithMalformedHooksMentioningSiftHasSomething() throws {
        let directory = try Self.scratchDirectory()
        try Data("{\"hooks\": [/x/sift".utf8).write(to: directory.appendingPathComponent("hooks.json"))

        #expect(try !Self.codex(directory, FakeCodex()).hasNothingOfSift)
    }

    private static func bareHome() throws -> URL {
        let home = try TemporaryDirectory.make("doctor-absent-bare")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude", isDirectory: true), withIntermediateDirectories: true)
        return home
    }

    private static func scratchDirectory() throws -> URL {
        let directory = try TemporaryDirectory.make("doctor-absent-dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func claude(_ home: URL) throws -> DoctorClaude {
        let environment = InstallCommandHarness.environment(home: home)
        return try DoctorClaude(environment: environment, probe: spentProbe())
    }

    private static func cursor(_ directory: URL) throws -> DoctorCursor {
        try DoctorCursor(directory: directory, probe: spentProbe())
    }

    private static func codex(_ directory: URL, _ runner: FakeCodex) throws -> DoctorCodex {
        try DoctorCodex(home: CodexInstall.home(flag: directory.path, environment: [:]), runner: runner, probe: spentProbe())
    }

    /// A probe already closed: `hasNothingOfSift` runs nothing, and the scratch the probe made is gone.
    private static func spentProbe() throws -> DoctorProbe {
        let probe = try DoctorProbe(environment: [:])
        probe.close()
        return probe
    }

    private static func write(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    private static func unreadable(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    }

    private static func restore(_ file: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    /// A scratch home where Claude Code is found and wired to a binary that need not run (or left bare), with `~/.cursor` there or not, and nothing else found.
    private static func machine(cursorDirectory: Bool, claudeInstalled: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentDetection.Machine {
        let home = try TemporaryDirectory.make("doctor-absent")
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        if cursorDirectory {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor", isDirectory: true), withIntermediateDirectories: true)
        }
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle", sourceLocation: sourceLocation).path
        var settings: Data?
        for event in HookRegistration.events {
            settings = try HookRegistration.apply(
                to: settings,
                command: "\(ShellWord.quoted(binary)) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        if claudeInstalled {
            try settings?.write(to: claude.appendingPathComponent("settings.json"))
            let config: [String: Any] = ["mcpServers": ["sift": ["type": "stdio", "command": binary, "args": ["mcp"]]]]
            try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"))
        }
        var environment = InstallCommandHarness.environment(home: home)
        environment["PATH"] = "/usr/bin:/bin"
        return AgentDetection.Machine(environment: environment, applications: home, pathLookup: { _ in nil })
    }

    private static func doctor(_ machine: AgentDetection.Machine, _ arguments: [String] = []) throws -> (printed: String, status: Int32) {
        let recorded = RecordedOutput()
        var command = try DoctorCommand.parse(arguments)
        command.output = recorded.output
        command.machine = machine
        do {
            try command.run()
        } catch let exit as ExitCode {
            return (recorded.printed, exit.rawValue)
        }
        return (recorded.printed, 0)
    }
}
