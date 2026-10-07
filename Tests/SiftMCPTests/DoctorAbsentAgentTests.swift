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
    func aFoundAgentWithoutSiftStillFails() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: true))

        #expect(run.status == 1, "\(run.printed)")
        #expect(run.printed.contains("cursor hooks: fail"), "\(run.printed)")
        #expect(run.printed.contains("codex: not detected, skipped"), "\(run.printed)")
    }

    @Test
    func anAgentNamedIsCheckedWhereItWasNotFound() throws {
        let run = try Self.doctor(Self.machine(cursorDirectory: false), ["--agent", "cursor"])

        #expect(run.status == 1, "\(run.printed)")
        #expect(run.printed.contains("cursor hooks: fail"), "\(run.printed)")
        #expect(!run.printed.contains("not detected, skipped"), "\(run.printed)")
    }

    /// A scratch home where Claude Code is found and wired to a binary that need not run, with `~/.cursor` there or not, and nothing else found.
    private static func machine(cursorDirectory: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentDetection.Machine {
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
        try settings?.write(to: claude.appendingPathComponent("settings.json"))
        let config: [String: Any] = ["mcpServers": ["sift": ["type": "stdio", "command": binary, "args": ["mcp"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"))
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
