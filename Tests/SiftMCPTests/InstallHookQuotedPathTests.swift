//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers a binary under a directory with a space in it: `install-hook` registers it shell-quoted, so the shell Claude Code runs a hook through reaches it, and an unquoted registration an older install wrote is repointed rather than left beside it.
@Suite(.temporaryDirectories)
struct InstallHookQuotedPathTests {
    private typealias Fixture = InstallHookBinaryPathTests

    /// Every hook names the binary quoted, the ownership rule still claims each, and each runs through `sh -c` and exits 0 rather than 127.
    @Test
    func aPathWithASpaceIsRegisteredQuotedAndRuns() throws {
        let scratch = try TemporaryDirectory.make("install-quoted")
        let binary = try Fixture.executable(at: "My Tools/sift", in: scratch, script: "#!/bin/sh\nexit 0\n")
        let settings = scratch.appendingPathComponent("settings.json")

        try Fixture.install(settings, path: binary.deletingLastPathComponent().path, home: scratch)

        let registered = try Fixture.registered(at: settings)
        #expect(registered.count == HookRegistration.events.count)
        for (command, subcommand) in registered {
            // Checked before anything is run, so a regression fails here rather than running whatever it names.
            try #require(command == "'\(binary.path)' \(subcommand)")
            #expect(Fixture.claims(command, subcommand: subcommand), "\(command)")
            #expect(try Self.exitStatus(ofShellCommand: command) == 0, "\(command)")
        }
    }

    /// An older install's unquoted registration of the same binary is replaced by the quoted one, leaving one hook per matcher and taking its status line out; a second run changes nothing.
    @Test
    func anUnquotedRegistrationIsReplacedOnceAndTheReRunChangesNothing() throws {
        let scratch = try TemporaryDirectory.make("install-quoted-upgrade")
        let binary = try Fixture.executable(at: "My Tools/sift", in: scratch)
        let settings = scratch.appendingPathComponent("settings.json")
        try Self.registerUnquoted(binary.path, in: settings)

        let printed = try Fixture.install(settings, path: binary.deletingLastPathComponent().path, home: scratch)

        #expect(printed.contains("hook: replaced stale registration (\(binary.path) session-start)"), "\(printed)")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = object["hooks"] as? [String: Any] ?? [:]
        for event in HookRegistration.events {
            let entries = try #require(hooks[event.name] as? [[String: Any]])
            #expect(entries.count == max(event.matchers.count, 1), "\(event.name)")
            for entry in entries {
                let commands = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                #expect(commands == ["'\(binary.path)' \(event.subcommand)"], "\(event.name)")
            }
        }
        #expect(object["statusLine"] == nil)

        let installed = try Data(contentsOf: settings)
        let again = try Fixture.install(settings, path: binary.deletingLastPathComponent().path, home: scratch)

        #expect(again.contains("hook: already registered ('\(binary.path)' session-start)"), "\(again)")
        #expect(try Data(contentsOf: settings) == installed)
    }

    /// A directory holding a quote followed by a combining mark (one `Character`, but still a quote to a shell) is written quoted with the quote escaped, so each command reaches the binary and nothing beside it runs.
    @Test
    func aQuoteFollowedByACombiningMarkIsEscapedAndReachesTheBinary() throws {
        let scratch = try TemporaryDirectory.make("install-quoted-mark")
        let log = scratch.appendingPathComponent("argv.log")
        let script = "#!/bin/sh\necho \"$@\" >> \(log.path)\n"
        let binary = try Fixture.executable(at: "a'\u{301};echo INJECTED;'\u{301}b/sift", in: scratch, script: script)
        let settings = scratch.appendingPathComponent("settings.json")

        try Fixture.install(settings, path: binary.deletingLastPathComponent().path, home: scratch)

        let registered = try Fixture.registered(at: settings)
        #expect(registered.count == HookRegistration.events.count)
        for (command, subcommand) in registered {
            try #require(command == ShellWord.quoted(binary.path) + " " + subcommand)
            try #require(command.hasPrefix("'"))
            #expect(Fixture.claims(command, subcommand: subcommand), "\(command)")
            #expect(try Self.exitStatus(ofShellCommand: command) == 0, "\(command)")
        }
        let logged = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(logged.sorted() == registered.map(\.subcommand).sorted())
    }
}

private extension InstallHookQuotedPathTests {
    /// Registers every event and the status line the way an install before quoting did, with `path` bare.
    static func registerUnquoted(_ path: String, in settings: URL) throws {
        var current: Data?
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "\(path) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try LegacyStatusLine.adding(command: "\(path) statusline", to: current).write(to: settings)
    }

    /// The exit status of `command` run the way Claude Code runs a hook, through `sh -c`, with nothing on its input.
    static func exitStatus(ofShellCommand command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
