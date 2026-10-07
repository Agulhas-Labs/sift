//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import SiftMCP
import Testing

/// `sift doctor` over a scratch Claude Code install whose hooks are all registered, with the `PostToolUse` matcher either this version's or the one before it.
@Suite(.temporaryDirectories)
struct DoctorStaleHookTests {
    private static var oldMatcher: String {
        "Write|Edit|MultiEdit"
    }

    @Test
    func aRegistrationWithAnOlderMatcherDoesNotPass() throws {
        let run = try Self.doctor(Self.machine(matcher: Self.oldMatcher))

        #expect(run.status == 1, "\(run.printed)")
        #expect(!run.printed.contains("claude hooks: pass"), "\(run.printed)")
        #expect(run.printed.contains("claude hooks: fail — "), "\(run.printed)")
        #expect(run.printed.contains("run `sift install --agent claude`"), "\(run.printed)")
    }

    @Test
    func aCurrentRegistrationPasses() throws {
        let current = try #require(HookRegistration.events.first { $0.name == "PostToolUse" }?.matchers.first)
        let run = try Self.doctor(Self.machine(matcher: current))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("claude hooks: pass — "), "\(run.printed)")
    }

    /// A scratch home where Claude Code is found and every hook and the server are registered for this build's `sift`, `PostToolUse` under `matcher`.
    private static func machine(matcher: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> AgentDetection.Machine {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle", sourceLocation: sourceLocation).path
        let home = try TemporaryDirectory.make("doctor-stale-home")
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        var settings: Data?
        for event in HookRegistration.events {
            settings = try HookRegistration.apply(
                to: settings,
                command: "\(ShellWord.quoted(binary)) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.name == "PostToolUse" ? [matcher] : event.matchers,
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

    private static func doctor(_ machine: AgentDetection.Machine) throws -> (printed: String, status: Int32) {
        let recorded = RecordedOutput()
        var command = try DoctorCommand.parse([])
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
