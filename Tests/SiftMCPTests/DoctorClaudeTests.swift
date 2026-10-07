//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import SiftMCP
import Testing

/// `sift doctor` over a scratch Claude Code install whose registrations name this build's `sift`, or a wrapper that breaks one thing.
@Suite(.temporaryDirectories)
struct DoctorClaudeTests {
    @Test
    func aWholeInstallPassesWithOneLinePerCheck() throws {
        let machine = try Self.machine(binary: Self.built())
        let run = try Self.doctor(machine)
        #expect(run.status == 0, "\(run.printed)")
        let lines = run.printed.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("doctor: passed — 0 of 11 checks failed; not detected: Cursor, Codex") == true, "\(run.printed)")
        let named = HookRegistration.events.map { "claude hook \($0.name): pass" } + ["claude hooks: pass", "claude server: pass", "claude binary: pass", "claude version: pass", "claude mcp server: pass"]
        for name in named {
            #expect(lines.count { $0.hasPrefix(name + " — ") } == 1, "\(name) in \(run.printed)")
        }
        #expect(lines.count { $0.contains(": not detected, skipped — ") } == 2)
    }

    @Test
    func aMissingBinaryFailsTheBinaryCheck() throws {
        let machine = try Self.machine(binary: "/no/such/place/sift")
        let run = try Self.doctor(machine)

        #expect(run.status == 1)
        #expect(run.printed.contains("claude binary: fail — /no/such/place/sift is not there, or is not executable"), "\(run.printed)")
    }

    @Test
    func aHookThatExitsNonZeroFailsItsOwnLine() throws {
        let wrapper = try Self.wrapper(failing: "pre-tool-use", status: 3)
        let run = try Self.doctor(Self.machine(binary: wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("claude hook PreToolUse: fail — exited 3"), "\(run.printed)")
        #expect(run.printed.contains("claude hook PostToolUse: pass"), "\(run.printed)")
    }

    @Test
    func aServerThatDoesNotStartFailsTheServerCheck() throws {
        let wrapper = try Self.wrapper(failing: "mcp", status: 1)
        let run = try Self.doctor(Self.machine(binary: wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("claude mcp server: fail — answered nothing (exit 1)"), "\(run.printed)")
        #expect(run.printed.contains("claude binary: pass"), "\(run.printed)")
    }

    @Test
    func anAgentNotDetectedIsSkippedAndPasses() throws {
        let home = try TemporaryDirectory.make("doctor-empty")
        let machine = AgentDetection.Machine(environment: InstallCommandHarness.environment(home: home), applications: home, pathLookup: { _ in nil })
        let run = try Self.doctor(machine)

        #expect(run.status == 0)
        #expect(run.printed.hasPrefix("doctor: passed — 0 of 0 checks failed; not detected: Claude Code, Cursor, Codex\n"), "\(run.printed)")
        #expect(run.printed.contains("claude: not detected, skipped — looked for"))
    }

    @Test
    func theJSONAnswerParsesAndCarriesEveryPrintedLine() throws {
        let wrapper = try Self.wrapper(failing: "stop", status: 2)
        let machine = try Self.machine(binary: wrapper)
        let text = try Self.doctor(machine)
        let json = try Self.doctor(machine, ["--json"])
        #expect(json.status == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.printed.utf8)) as? [String: Any])
        #expect(object["verdict"] as? String == "failed")
        let lines = try #require(object["checks"] as? [[String: Any]]).compactMap { $0["line"] as? String }
        let printed = text.printed.split(separator: "\n").map(String.init)
        #expect(lines.count == 11)
        #expect(lines == Array(printed.dropFirst().prefix(lines.count)))
    }

    /// This build's `sift`.
    private static func built(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle", sourceLocation: sourceLocation).path
    }

    /// A `sift` that runs this build's, except that `subcommand` exits `status` at once.
    private static func wrapper(failing subcommand: String, status: Int32) throws -> String {
        let directory = try TemporaryDirectory.make("doctor-wrapper")
        let wrapper = directory.appendingPathComponent("sift")
        let script = try "#!/bin/sh\nif [ \"$1\" = \(subcommand) ]; then exit \(status); fi\nexec \(ShellWord.quoted(built())) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    /// A scratch home where Claude Code is found and every hook and the server are registered for `binary`.
    private static func machine(binary: String) throws -> AgentDetection.Machine {
        let home = try TemporaryDirectory.make("doctor-home")
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
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
