//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import SiftMCP
import Testing

/// `sift doctor` over a scratch Codex home whose `hooks.json`, trust records and `codex mcp` server name this build's `sift`, or a wrapper that breaks one thing.
@Suite(.temporaryDirectories)
struct DoctorCodexTests {
    @Test
    func aWholeCodexInstallPassesWithOneLinePerCheck() throws {
        let binary = try Self.built()
        let run = try Self.doctor(Self.machine(binary: binary), codex: Self.registered(binary))
        #expect(run.status == 0, "\(run.printed)")
        let lines = run.printed.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("doctor: passed — 0 of 9 checks failed; not detected: Claude Code, Cursor") == true, "\(run.printed)")
        let named = CodexHooksFile.hooks.map { "codex hook \($0.event): pass" }
            + ["codex hooks: pass", "codex trust: pass", "codex server: pass", "codex binary: pass", "codex version: pass", "codex mcp server: pass"]
        for name in named {
            #expect(lines.count { $0.hasPrefix(name + " — ") } == 1, "\(name) in \(run.printed)")
        }
        #expect(run.printed.contains("codex trust: pass — trust recorded for 3 of 3 in "), "\(run.printed)")
    }

    @Test
    func aMissingBinaryFailsTheCodexBinaryCheck() throws {
        let binary = "/no/such/place/sift"
        let run = try Self.doctor(Self.machine(binary: binary), codex: Self.registered(binary))

        #expect(run.status == 1)
        #expect(run.printed.contains("codex binary: fail — /no/such/place/sift is not there, or is not executable"), "\(run.printed)")
    }

    @Test
    func aCodexHookThatExitsNonZeroFailsItsOwnLine() throws {
        let wrapper = try Self.wrapper(failing: "pre-tool-use", status: 3)
        let run = try Self.doctor(Self.machine(binary: wrapper), codex: Self.registered(wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("codex hook PreToolUse: fail — exited 3"), "\(run.printed)")
        #expect(run.printed.contains("codex hook PostToolUse: pass"), "\(run.printed)")
    }

    @Test
    func aCodexServerThatDoesNotStartFailsTheMcpServerCheck() throws {
        let wrapper = try Self.wrapper(failing: "mcp", status: 1)
        let run = try Self.doctor(Self.machine(binary: wrapper), codex: Self.registered(wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("codex mcp server: fail — answered nothing (exit 1)"), "\(run.printed)")
        #expect(run.printed.contains("codex binary: pass"), "\(run.printed)")
    }

    @Test
    func aCodexWithNoSiftServerFailsWithTheInstallHint() throws {
        let run = try Self.doctor(Self.machine(binary: Self.built()), codex: FakeCodex())

        #expect(run.status == 1)
        #expect(run.printed.contains("codex server: fail — no MCP server named sift in "), "\(run.printed)")
        #expect(run.printed.contains("; run `sift install --agent codex`"), "\(run.printed)")
        #expect(!run.printed.contains("codex mcp server:"), "\(run.printed)")
    }

    @Test
    func aCodexHomeWithoutHooksFailsTheHooksCheck() throws {
        let binary = try Self.built()
        let run = try Self.doctor(Self.machine(binary: binary, hooks: false), codex: Self.registered(binary))

        #expect(run.status == 1)
        #expect(run.printed.contains("codex hooks: fail — not registered for SessionStart, PreToolUse, PostToolUse in "), "\(run.printed)")
        #expect(!run.printed.contains("codex trust:"), "\(run.printed)")
    }

    @Test
    func trustIsLookedUpAtTheHandlersPositionPastForeignGroups() throws {
        let binary = try Self.built()
        let machine = try Self.machine(binary: binary, foreignFirst: true)
        let config = try String(contentsOf: Self.codexHome(machine).appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(config.contains(":pre_tool_use:1:0\"]"), "\(config)")
        let run = try Self.doctor(machine, codex: Self.registered(binary))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex trust: pass — trust recorded for 3 of 3 in "), "\(run.printed)")
    }

    @Test
    func aPartialTrustRecordIsUnknownWithItsCount() throws {
        let binary = try Self.built()
        let run = try Self.doctor(Self.machine(binary: binary, trusted: 2), codex: Self.registered(binary))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex trust: unknown — trust recorded for 2 of 3 in "), "\(run.printed)")
    }

    @Test
    func anAbsentConfigTomlLeavesTrustUnknownAndPassing() throws {
        let binary = try Self.built()
        let run = try Self.doctor(Self.machine(binary: binary, trusted: nil), codex: Self.registered(binary))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex trust: unknown — no "), "\(run.printed)")
    }

    @Test
    func aCodexNotOnPathLeavesTheServerUnknownAndRunsTheHooks() throws {
        let run = try Self.doctor(Self.machine(binary: Self.built()), codex: FakeCodex(present: false))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex server: unknown — `codex` is not on PATH"), "\(run.printed)")
        #expect(run.printed.contains("codex hook PreToolUse: pass"), "\(run.printed)")
        #expect(!run.printed.contains("codex binary:"), "\(run.printed)")
    }

    @Test
    func aCodexThatCannotReadItsServersLeavesTheServerUnknown() throws {
        let run = try Self.doctor(Self.machine(binary: Self.built()), codex: FakeCodex(getError: "Error: failed to parse config.toml"))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex server: unknown — `codex mcp get sift --json` did not answer: "), "\(run.printed)")
        #expect(run.printed.contains("failed to parse config.toml"), "\(run.printed)")
    }

    @Test
    func theCodexDirFlagPointsDoctorPastTheDefaultHome() throws {
        let binary = try Self.built()
        let elsewhere = try TemporaryDirectory.make("doctor-codex-elsewhere")
        let machine = try Self.machine(binary: binary, codexHome: elsewhere)
        // An empty default home, so Codex is detected and only the flag leads to the registered one.
        try FileManager.default.createDirectory(at: Self.codexHome(machine), withIntermediateDirectories: true)
        let codex = Self.registered(binary)
        let run = try Self.doctor(machine, ["--codex-dir", elsewhere.path], codex: codex)

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex hooks: pass — registered for SessionStart, PreToolUse, PostToolUse in \(elsewhere.appendingPathComponent("hooks.json").path) (Codex home from --codex-dir)"), "\(run.printed)")
        #expect(codex.calls.map(\.home) == [elsewhere.path])
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--agent", "claude", "--codex-dir", elsewhere.path]) }
    }

    @Test
    func theCodexDirFlagAloneChecksAHomeDetectionCannotFind() throws {
        let binary = try Self.built()
        let elsewhere = try TemporaryDirectory.make("doctor-codex-undetected")
        // No default home, so detection finds no Codex and only the flag leads to one.
        let machine = try Self.machine(binary: binary, codexHome: elsewhere)
        #expect(!FileManager.default.fileExists(atPath: Self.codexHome(machine).path))
        let run = try Self.doctor(machine, ["--codex-dir", elsewhere.path], codex: Self.registered(binary))

        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.contains("codex hooks: pass"), "\(run.printed)")
    }

    /// This build's `sift`.
    private static func built(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle", sourceLocation: sourceLocation).path
    }

    /// A `codex` holding `binary` as the server named `sift`.
    private static func registered(_ binary: String) -> FakeCodex {
        FakeCodex(server: (binary, ["mcp"]))
    }

    /// A `sift` that runs this build's, except that `subcommand` exits `status` at once.
    private static func wrapper(failing subcommand: String, status: Int32) throws -> String {
        let directory = try TemporaryDirectory.make("doctor-codex-wrapper")
        let wrapper = directory.appendingPathComponent("sift")
        let script = try "#!/bin/sh\nif [ \"$1\" = \(subcommand) ]; then exit \(status); fi\nexec \(ShellWord.quoted(built())) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    /// The Codex home `machine` resolves to without a flag.
    private static func codexHome(_ machine: AgentDetection.Machine) -> URL {
        SiftPaths.codexDirectory(environment: machine.environment)
    }

    /// A scratch home where only Codex is found: its hooks registered for `binary` in the Codex home given (else `~/.codex`), behind a foreign `PreToolUse` group when asked, and that many of them recorded as trusted in `config.toml`, which `nil` leaves out.
    private static func machine(binary: String, hooks: Bool = true, foreignFirst: Bool = false, trusted: Int? = 3, codexHome: URL? = nil) throws -> AgentDetection.Machine {
        let home = try TemporaryDirectory.make("doctor-codex-home")
        var environment = InstallCommandHarness.environment(home: home)
        environment["PATH"] = "/usr/bin:/bin"
        let directory = codexHome ?? SiftPaths.codexDirectory(environment: environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(CodexHooksFile.fileName)
        if hooks {
            let foreign: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"]]]]]]
            let seed = foreignFirst ? try JSONSerialization.data(withJSONObject: foreign) : nil
            try CodexHooksFile.apply(to: seed, binaryWord: ShellWord.quoted(binary)).data.write(to: file)
        }
        if let trusted, hooks {
            // The key is written with the path resolved, so the doctor's canonical comparison is what matches it.
            let registered = try DoctorCodex.registeredHooks(in: Data(contentsOf: file)).prefix(trusted)
            let config = registered.map { hook in
                let position = hook.position
                return "[hooks.state.\"\(file.resolvingSymlinksInPath().path):\(position.event):\(position.group):\(position.handler)\"]\ntrusted_hash = \"sha256:0f\"\n"
            }
            try (["[mcp_servers.sift]\ncommand = \"\(binary)\"\n"] + config).joined(separator: "\n").write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        return AgentDetection.Machine(environment: environment, applications: home, pathLookup: { _ in nil })
    }

    private static func doctor(_ machine: AgentDetection.Machine, _ arguments: [String] = [], codex: FakeCodex) throws -> (printed: String, status: Int32) {
        let recorded = RecordedOutput()
        var command = try DoctorCommand.parse(arguments)
        command.output = recorded.output
        command.machine = machine
        command.codex = codex
        do {
            try command.run()
        } catch let exit as ExitCode {
            return (recorded.printed, exit.rawValue)
        }
        return (recorded.printed, 0)
    }
}
