//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the binary `install-hook` registers: the one the shell ran, found on PATH when started by its bare name as the Homebrew caveat starts it, and a link on PATH kept as the link.
@Suite(.temporaryDirectories)
struct InstallHookBinaryPathTests {
    /// Started by the bare name, the install registers the binary PATH found for every hook, never a conventional location nothing was installed to.
    @Test
    func aBareNameRegistersTheBinaryFoundOnPath() throws {
        let scratch = try TemporaryDirectory.make("install-path")
        let binary = try Self.executable(at: "bin/sift", in: scratch)
        let settings = scratch.appendingPathComponent("settings.json")

        try Self.install(settings, path: "\(scratch.path)/empty:\(binary.deletingLastPathComponent().path)", home: scratch)

        let registered = try Self.registered(at: settings)
        #expect(registered.count == HookRegistration.events.count)
        for (command, subcommand) in registered {
            #expect(command == "\(binary.path) \(subcommand)")
            #expect(Self.claims(command, subcommand: subcommand), "\(command)")
        }
    }

    /// Homebrew's link on PATH is what the hooks run, not the Cellar copy it points into, which the next upgrade removes.
    @Test
    func aLinkOnPathIsRegisteredAsTheLink() throws {
        let scratch = try TemporaryDirectory.make("install-path-link")
        try Self.executable(at: "Cellar/sift/1.0/bin/sift", in: scratch)
        let bin = scratch.appendingPathComponent("brewbin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("sift")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Cellar/sift/1.0/bin/sift")
        let settings = scratch.appendingPathComponent("settings.json")

        try Self.install(settings, path: bin.path, home: scratch)

        let registered = try Self.registered(at: settings)
        #expect(!registered.isEmpty)
        for (command, subcommand) in registered {
            #expect(command == "\(link.path) \(subcommand)")
            #expect(Self.claims(command, subcommand: subcommand), "\(command)")
        }
    }

    /// A path to the binary is taken as given; a bare name found nowhere on PATH falls back to this process's executable, and only with none of those to the conventional install location.
    @Test
    func theFallbacksRunFromTheInvokedPathToTheInstallLocation() throws {
        let scratch = try TemporaryDirectory.make("install-path-fallback")
        let binary = try Self.executable(at: "bin/sift", in: scratch)
        let environment = ["PATH": "\(scratch.path)/empty:relative/bin", "CFFIXED_USER_HOME": scratch.path]

        let given = InstallHookCommand.binaryPath(invokedAs: "\(scratch.path)/bin/../bin/sift", environment: environment, executable: nil)
        let running = InstallHookCommand.binaryPath(invokedAs: "sift", environment: environment, executable: binary.path)
        let none = InstallHookCommand.binaryPath(invokedAs: "sift", environment: environment, executable: nil)

        #expect(given == binary.path)
        #expect(running == binary.path)
        #expect(none == scratch.appendingPathComponent(".local/bin/sift").path)
    }

    /// A bare name that PATH resolves to a different file from the one running is not what ran: a relative PATH entry the shell used, or a wrapper that exec'd with a bare name, leaves the running binary's own path to be registered.
    @Test
    func aPathMatchThatIsNotTheRunningBinaryIsNotRegistered() throws {
        let scratch = try TemporaryDirectory.make("install-path-other")
        let other = try Self.executable(at: "abs/sift", in: scratch)
        let running = try Self.executable(at: "bin/sift", in: scratch)
        let environment = ["PATH": "bin:\(other.deletingLastPathComponent().path)", "CFFIXED_USER_HOME": scratch.path]
        let wrapped = ["PATH": other.deletingLastPathComponent().path, "CFFIXED_USER_HOME": scratch.path]

        let relative = InstallHookCommand.binaryPath(invokedAs: "sift", environment: environment, executable: running.path)
        let wrapper = InstallHookCommand.binaryPath(invokedAs: "sift", environment: wrapped, executable: running.path)
        let same = InstallHookCommand.binaryPath(invokedAs: "sift", environment: wrapped, executable: other.path)

        #expect(relative == running.path)
        #expect(wrapper == running.path)
        #expect(same == other.path)
    }

    /// The same rule end to end: an install whose process is `bin/sift`, with another `sift` first on PATH, writes `bin/sift`.
    @Test
    func theInstallRegistersTheRunningBinaryNotAnEarlierOneOnPath() throws {
        let scratch = try TemporaryDirectory.make("install-path-running")
        let other = try Self.executable(at: "abs/sift", in: scratch)
        let running = try Self.executable(at: "bin/sift", in: scratch)
        let settings = scratch.appendingPathComponent("settings.json")

        try Self.install(settings, path: other.deletingLastPathComponent().path, home: scratch, running: running.path)

        for (command, subcommand) in try Self.registered(at: settings) {
            #expect(command == "\(running.path) \(subcommand)")
        }
    }
}

extension InstallHookBinaryPathTests {
    /// A binary inside npx's cache is refused before a byte of settings is written: the tree is evicted per version, and every hook registered there would then exit 127.
    @Test
    func aBinaryInNpxsCacheIsRefusedAndNothingIsWritten() throws {
        let scratch = try TemporaryDirectory.make("install-path-npx")
        let cached = try Self.executable(at: ".npm/_npx/abc123/node_modules/@agulhas-labs/sift-darwin-arm64/bin/sift", in: scratch)
        let settings = scratch.appendingPathComponent("settings.json")

        #expect(throws: (any Error).self) {
            try Self.install(settings, path: cached.deletingLastPathComponent().path, home: scratch, running: cached.path)
        }
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    /// The refusal is for npx's cache alone: a global npm install, which also sits under `node_modules`, registers as before.
    @Test
    func aGlobalNpmInstallIsNotRefused() throws {
        let scratch = try TemporaryDirectory.make("install-path-npm-global")
        let global = try Self.executable(at: "lib/node_modules/@agulhas-labs/sift-darwin-arm64/bin/sift", in: scratch)
        let settings = scratch.appendingPathComponent("settings.json")

        try Self.install(settings, path: global.deletingLastPathComponent().path, home: scratch, running: global.path)

        #expect(try !Self.registered(at: settings).isEmpty)
    }

    /// Whether the registration running `subcommand` would claim `command` on a re-run or an uninstall.
    static func claims(_ command: String, subcommand: String) -> Bool {
        HookRegistration.isOurs(command, subcommand: subcommand)
    }

    /// Every command the settings at `url` register for each hook event, with the subcommand each runs.
    static func registered(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [(command: String, subcommand: String)] {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
        let hooks = object["hooks"] as? [String: Any] ?? [:]
        var registered: [(command: String, subcommand: String)] = []
        for event in HookRegistration.events {
            let entries = hooks[event.name] as? [[String: Any]] ?? []
            let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
            registered += Set(commands).map { ($0, event.subcommand) }
        }
        return registered
    }

    /// An executable file at `relative` under `root` holding `script`, with its directories.
    @discardableResult
    static func executable(at relative: String, in root: URL, script: String = "#!/bin/sh\n") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Runs `install-hook` against `settings` as started by the bare name, with `path` as PATH and `home` as the home, answering what it printed.
    ///
    /// `running` is the file the process is: by default the one PATH finds first, the ordinary case of a shell that ran what it found.
    @discardableResult
    static func install(_ settings: URL, path: String, home: URL, running: String? = nil) throws -> String {
        let environment = ["PATH": path, "CFFIXED_USER_HOME": home.path]
        var command = try InstallHookCommand.parse(["--settings", settings.path, "--no-allow-run"])
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.arguments = [SiftPaths.binaryName, "install-hook"]
        command.environment = environment
        command.executable = running ?? InvokedBinary.onPath(SiftPaths.binaryName, environment: environment)
        try command.run()
        return recorded.printed
    }
}
