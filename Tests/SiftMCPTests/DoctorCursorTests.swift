//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import SiftMCP
import Testing

/// `sift doctor` over a scratch Cursor directory written by the real Cursor install for this build's `sift`, or a wrapper that breaks one thing.
@Suite(.temporaryDirectories)
struct DoctorCursorTests {
    @Test
    func aWholeInstallPassesWithOneLinePerCheck() throws {
        let machine = try Self.machine(binary: Self.built())
        let run = try Self.doctor(machine)
        #expect(run.status == 0, "\(run.printed)")
        let lines = run.printed.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("doctor: passed — 0 of 8 checks failed; not detected: Claude Code, Codex") == true, "\(run.printed)")
        let named = CursorHooksFile.hooks.map { "cursor hook \($0.event): pass" } + ["cursor hooks: pass", "cursor server: pass", "cursor binary: pass", "cursor version: pass", "cursor mcp server: pass"]
        for name in named {
            #expect(lines.count { $0.hasPrefix(name + " — ") } == 1, "\(name) in \(run.printed)")
        }
    }

    @Test
    func aMissingBinaryFailsTheBinaryCheck() throws {
        let run = try Self.doctor(Self.machine(binary: "/no/such/place/sift"))

        #expect(run.status == 1)
        #expect(run.printed.contains("cursor binary: fail — /no/such/place/sift is not there, or is not executable"), "\(run.printed)")
    }

    @Test
    func aHookThatExitsNonZeroFailsItsOwnLine() throws {
        let wrapper = try Self.wrapper(failing: "pre-tool-use", with: "exit 3")
        let run = try Self.doctor(Self.machine(binary: wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("cursor hook preToolUse: fail — exited 3"), "\(run.printed)")
        #expect(run.printed.contains("cursor hook postToolUse: pass"), "\(run.printed)")
    }

    @Test
    func aServerThatDoesNotStartFailsTheServerCheck() throws {
        let wrapper = try Self.wrapper(failing: "mcp", with: "exit 1")
        let run = try Self.doctor(Self.machine(binary: wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("cursor mcp server: fail — answered nothing (exit 1)"), "\(run.printed)")
        #expect(run.printed.contains("cursor binary: pass"), "\(run.printed)")
    }

    @Test
    func aHookThatPrintsTextFailsSinceCursorReadsOnlyJSON() throws {
        let wrapper = try Self.wrapper(failing: "session-start", with: "echo primer; exit 0")
        let run = try Self.doctor(Self.machine(binary: wrapper))

        #expect(run.status == 1)
        #expect(run.printed.contains("cursor hook sessionStart: fail — exit 0, but printed something other than a JSON object"), "\(run.printed)")
    }

    @Test
    func aCursorDirectoryWithNothingRegisteredSaysToInstall() throws {
        let home = try TemporaryDirectory.make("doctor-cursor-bare")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor", isDirectory: true), withIntermediateDirectories: true)
        let run = try Self.doctor(Self.machine(home: home))

        #expect(run.status == 1)
        #expect(run.printed.contains("cursor hooks: fail — not registered for sessionStart, preToolUse, postToolUse in "), "\(run.printed)")
        #expect(run.printed.contains("cursor server: fail — no MCP server named sift of this tool's in "), "\(run.printed)")
        #expect(run.printed.split(separator: "\n").count { $0.hasPrefix("cursor ") && $0.hasSuffix("run `sift install --agent cursor`") } == 2, "\(run.printed)")
    }

    @Test
    func theCursorDirFlagChecksThatDirectoryEvenWhereCursorIsNotFound() throws {
        let home = try TemporaryDirectory.make("doctor-cursor-home")
        let directory = try TemporaryDirectory.make("doctor-cursor-elsewhere")
        _ = try CursorInstall.install(directory: directory, binary: Self.built(), binaryWord: ShellWord.quoted(Self.built()))
        let machine = Self.machine(home: home)
        let skipped = try Self.doctor(machine)
        let run = try Self.doctor(machine, ["--agent", "cursor", "--cursor-dir", directory.path])

        #expect(skipped.printed.contains("cursor: not detected, skipped"), "\(skipped.printed)")
        #expect(run.status == 0, "\(run.printed)")
        #expect(run.printed.hasPrefix("doctor: passed — 0 of 8 checks failed\n"), "\(run.printed)")
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--agent", "claude", "--cursor-dir", directory.path]) }
    }

    @Test
    func eachPayloadIsOneTheCursorHandlerReadsInTheShapeCursorSends() throws {
        let workspace = try TemporaryDirectory.make("doctor-cursor-workspace")
        let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("cursor-hook-payloads.json"))) as? [String: Any])
        let common = try #require(fixture["common"] as? [String: Any])
        let events = try #require(fixture["events"] as? [String: [String: Any]])
        for hook in CursorHooksFile.hooks {
            let payload = DoctorCursor.payload(for: hook.event, workspace: workspace)
            let recorded = try #require(events[hook.event], "no recorded \(hook.event)")
            let unknown = Set(payload.keys).subtracting(common.keys).subtracting(recorded.keys)
            #expect(unknown.isEmpty, "\(hook.event) carries \(unknown.sorted()), which Cursor was never seen to send")
            #expect(payload["hook_event_name"] as? String == recorded["hook_event_name"] as? String)
        }

        #expect(CursorSessionStart.claudePayload(from: DoctorCursor.payload(for: "sessionStart", workspace: workspace)) != nil)
        #expect(CursorPreToolUse.claudePayload(from: DoctorCursor.payload(for: "preToolUse", workspace: workspace))?["tool_name"] as? String == "Bash")
        #expect(CursorPostToolUse.claudePayload(from: DoctorCursor.payload(for: "postToolUse", workspace: workspace)) != nil)
    }

    @Test
    func theJSONAnswerParsesAndCarriesEveryPrintedLine() throws {
        let wrapper = try Self.wrapper(failing: "post-tool-use", with: "exit 2")
        let machine = try Self.machine(binary: wrapper)
        let text = try Self.doctor(machine)
        let json = try Self.doctor(machine, ["--json"])
        #expect(json.status == 1)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.printed.utf8)) as? [String: Any])
        #expect(object["verdict"] as? String == "failed")
        let checks = try #require(object["checks"] as? [[String: Any]])
        let lines = checks.compactMap { $0["line"] as? String }
        let printed = text.printed.split(separator: "\n").map(String.init)
        #expect(lines.count == 8)
        #expect(checks.allSatisfy { $0["agent"] as? String == "cursor" })
        #expect(lines == Array(printed.dropFirst().prefix(lines.count)))
        #expect(lines.contains { $0.hasPrefix("cursor hook postToolUse: fail — exited 2") }, "\(lines)")
    }

    private static var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// This build's `sift`.
    private static func built(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle", sourceLocation: sourceLocation).path
    }

    /// A `sift` that runs this build's, except that `subcommand` runs `body` instead.
    private static func wrapper(failing subcommand: String, with body: String) throws -> String {
        let directory = try TemporaryDirectory.make("doctor-cursor-wrapper")
        let wrapper = directory.appendingPathComponent("sift")
        let script = try "#!/bin/sh\nif [ \"$1\" = \(subcommand) ]; then \(body); fi\nexec \(ShellWord.quoted(built())) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper.path
    }

    /// A scratch home where Cursor is found and the real Cursor install has registered the server and every hook for `binary`.
    private static func machine(binary: String) throws -> AgentDetection.Machine {
        let home = try TemporaryDirectory.make("doctor-cursor-home")
        let directory = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try CursorInstall.install(directory: directory, binary: binary, binaryWord: ShellWord.quoted(binary))
        return machine(home: home)
    }

    /// Detection's view of a machine whose home is `home`, with nothing on the PATH it looks for and no applications.
    private static func machine(home: URL) -> AgentDetection.Machine {
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
