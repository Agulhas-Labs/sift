//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `install-hook --agent codex` and `uninstall-hook --agent codex`: the hooks in the Codex home's `hooks.json`, the server through a `codex` that is always a fake here.
@Suite(.temporaryDirectories) struct CodexInstallHookTests {
    private static var foreignHooks: String {
        #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"/usr/local/bin/audit-log.sh","type":"command"}],"matcher":"Bash"}]}}"#
    }

    @Test
    func theInstallWritesTheHooksAsksBeforeAddingAndSaysWhatCodexDoesNotGet() throws {
        let scratch = try TemporaryDirectory.make("codex-install")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = scratch.appendingPathComponent("codex-home")
        let codex = FakeCodex()

        let printed = try Self.install(["--codex-dir", home.path], binary: binary, codex: codex)

        #expect(codex.calls == [
            FakeCodex.Call(arguments: ["mcp", "get", "sift", "--json"], home: home.path),
            FakeCodex.Call(arguments: ["mcp", "add", "sift", "--", binary.path, "mcp"], home: home.path),
        ])
        let events = try #require(CursorInstallHookTests.object(at: home.appendingPathComponent("hooks.json"))["hooks"] as? [String: Any])
        #expect(Set(events.keys) == ["SessionStart", "PreToolUse", "PostToolUse"])
        #expect(printed.hasPrefix("codex home: \(home.path) (--codex-dir)\n"), "\(printed)")
        #expect(printed.contains("mcp: registered sift — \(binary.path) mcp"), "\(printed)")
        #expect(printed.contains(CodexHookInstaller.restart), "\(printed)")
        #expect(!printed.contains("run /hooks"), "\(printed)")
        for line in CodexInstall.unsupported + [CodexHookInstaller.experimental] {
            #expect(printed.contains(line), "\(line)")
        }
    }

    @Test
    func aSecondInstallChangesNothingAndTheUninstallRestoresTheForeignHooks() throws {
        let scratch = try TemporaryDirectory.make("codex-idempotent")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = try Self.codexHome(in: scratch, hooks: Self.foreignHooks)
        let foreign = try Data(contentsOf: home.appendingPathComponent("hooks.json"))
        let codex = FakeCodex()

        try Self.install(["--codex-dir", home.path], binary: binary, codex: codex)
        let installed = try Data(contentsOf: home.appendingPathComponent("hooks.json"))
        let again = try Self.install(["--codex-dir", home.path], binary: binary, codex: codex)
        let removed = try Self.uninstall(home, codex: codex)
        let removedAgain = try Self.uninstall(home, codex: codex)

        #expect(again.contains("hooks: already registered — SessionStart, PreToolUse, PostToolUse"), "\(again)")
        #expect(again.contains("mcp: already registered — \(binary.path) mcp"), "\(again)")
        #expect(codex.calls.map(\.arguments).filter { $0[1] == "add" }.count == 1)
        #expect(removed.contains("mcp: removed sift — \(binary.path) mcp"), "\(removed)")
        #expect(removed.contains("hooks: removed PreToolUse — \(binary.path) pre-tool-use"), "\(removed)")
        #expect(codex.calls.last?.arguments == ["mcp", "get", "sift", "--json"])
        #expect(codex.calls.map(\.arguments).contains(["mcp", "remove", "sift"]))
        #expect(try Data(contentsOf: home.appendingPathComponent("hooks.json")) == foreign)
        #expect(installed != foreign)
        #expect(removedAgain.contains("codex: nothing registered in \(home.path)"), "\(removedAgain)")
    }

    @Test
    func aServerNamedSiftOfAnotherShapeIsReportedAndLeftAloneWhileTheHooksGoIn() throws {
        let scratch = try TemporaryDirectory.make("codex-foreign-server")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = scratch.appendingPathComponent("codex-home")
        let codex = FakeCodex(server: (command: "/opt/notes/bin/notes", arguments: ["serve"]))

        let printed = try Self.install(["--codex-dir", home.path], binary: binary, codex: codex)
        let removed = try Self.uninstall(home, codex: codex)

        #expect(codex.calls.map(\.arguments) == [["mcp", "get", "sift", "--json"], ["mcp", "get", "sift", "--json"]])
        #expect(printed.contains("mcp: left alone — a server named sift runs something else (/opt/notes/bin/notes serve)"), "\(printed)")
        #expect(removed.contains("mcp: not ours, left alone"), "\(removed)")
        #expect(codex.server?.command == "/opt/notes/bin/notes")
    }

    @Test
    func withoutCodexOnPathTheHooksGoInAndTheExactAddCommandIsPrinted() throws {
        let scratch = try TemporaryDirectory.make("codex-absent")
        let binary = try CursorInstallHookTests.binary(in: scratch, at: "my tools/sift")
        let home = scratch.appendingPathComponent("codex-home")
        let codex = FakeCodex(present: false)

        let command = "codex mcp add sift -- \(ShellWord.quoted(binary.path)) mcp"

        let printed = try Self.install(["--codex-dir", home.path], binary: binary, codex: codex)
        let removed = try Self.uninstall(home, codex: codex)

        #expect(printed.contains("mcp: `codex` is not on PATH — register the server with: CODEX_HOME=\(ShellWord.quoted(home.path)) \(command)"), "\(printed)")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks.json").path))
        #expect(removed.contains("mcp: not checked — `codex` is not on PATH"), "\(removed)")
    }

    @Test
    func aGetThatFailsForAnotherReasonRefusesAndWritesNothing() throws {
        let scratch = try TemporaryDirectory.make("codex-get-fails")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = try Self.codexHome(in: scratch, hooks: Self.foreignHooks)
        let before = try Data(contentsOf: home.appendingPathComponent("hooks.json"))
        let codex = FakeCodex(getError: "Error: failed to load bootstrap configuration")

        let error = try #require(throws: CursorInstall.Refused.self) { try Self.install(["--codex-dir", home.path], binary: binary, codex: codex) }

        #expect(error.description.hasPrefix("codex: nothing written — \(home.path)/config.toml"), "\(error)")
        #expect(try Data(contentsOf: home.appendingPathComponent("hooks.json")) == before)
        #expect(codex.calls.count == 1)
    }

    @Test
    func aSymlinkedHooksFileIsWrittenThroughAndStaysALink() throws {
        let scratch = try TemporaryDirectory.make("codex-symlink")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let dotfiles = try Self.codexHome(in: scratch, named: "dotfiles", hooks: Self.foreignHooks)
        let home = scratch.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("hooks.json").path, withDestinationPath: "../dotfiles/hooks.json")

        try Self.install(["--codex-dir", home.path], binary: binary, codex: FakeCodex())

        #expect(PathKind.of(home.appendingPathComponent("hooks.json")) == .symlink("../dotfiles/hooks.json"))
        #expect(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("hooks.json.bak-sift").path))
        #expect(try (CursorInstallHookTests.object(at: dotfiles.appendingPathComponent("hooks.json"))["hooks"] as? [String: Any])?["SessionStart"] != nil)
    }

    @Test
    func anUnreadableHooksFileIsRefusedAndNothingIsRegistered() throws {
        let scratch = try TemporaryDirectory.make("codex-unreadable")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = try Self.codexHome(in: scratch, hooks: Self.foreignHooks)
        let hooks = home.appendingPathComponent("hooks.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hooks.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hooks.path) }
        let codex = FakeCodex()

        #expect(throws: CursorInstall.Refused.self) { try Self.install(["--codex-dir", home.path], binary: binary, codex: codex) }
        #expect(throws: CursorInstall.Refused.self) { try Self.uninstall(home, codex: codex) }

        #expect(codex.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: hooks.appendingPathExtension("bak-sift").path))
    }

    @Test
    func aLinkThatLeadsNowhereIsRefusedNamingTheCodexDirectoryFlag() throws {
        let scratch = try TemporaryDirectory.make("codex-dangling")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let home = scratch.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("hooks.json").path, withDestinationPath: "../nowhere/hooks.json")
        let codex = FakeCodex()

        let error = try #require(throws: CursorInstall.Refused.self) { try Self.install(["--codex-dir", home.path], binary: binary, codex: codex) }

        #expect(error.description.hasPrefix("codex: nothing written"), "\(error)")
        #expect(error.description.contains("--codex-dir"), "\(error)")
        #expect(codex.calls.isEmpty)
    }

    @Test(arguments: [
        ["--agent", "codex", "--settings", "/tmp/settings.json"],
        ["--agent", "codex", "--command", "/bin/sift session-start"],
        ["--agent", "codex", "--allow-run"],
        ["--agent", "codex", "--cursor-dir", "/tmp/cursor"],
        ["--agent", "cursor", "--codex-dir", "/tmp/codex"],
        ["--codex-dir", "/tmp/codex"],
    ])
    func anInstallFlagTheAgentHasNoUseForIsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try InstallHookCommand.parse(arguments) }
    }

    @Test(arguments: [
        ["--agent", "codex", "--settings", "/tmp/settings.json"],
        ["--agent", "codex", "--only-advice"],
        ["--agent", "codex", "--cursor-dir", "/tmp/cursor"],
        ["--agent", "cursor", "--codex-dir", "/tmp/codex"],
        ["--codex-dir", "/tmp/codex"],
    ])
    func anUninstallFlagTheAgentHasNoUseForIsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try UninstallHookCommand.parse(arguments) }
    }

    @Test
    func aRefusedClaudeFlagNamesCodex() throws {
        let error = try #require(throws: (any Error).self) { try InstallHookCommand.parse(["--agent", "codex", "--allow-lookups"]) }

        #expect(InstallHookCommand.message(for: error).contains("not Codex"), "\(InstallHookCommand.message(for: error))")
    }

    @Test
    func theCodexHomeIsTheFlagThenCodexHomeThenTheDotCodexDirectory() {
        let environment = ["CFFIXED_USER_HOME": "/scratch/home", "CODEX_HOME": "/scratch/codex"]

        #expect(CodexInstall.home(flag: "/scratch/flag", environment: environment).line == "codex home: /scratch/flag (--codex-dir)")
        #expect(CodexInstall.home(flag: nil, environment: environment).line == "codex home: /scratch/codex ($CODEX_HOME)")
        #expect(CodexInstall.home(flag: nil, environment: ["CFFIXED_USER_HOME": "/scratch/home", "CODEX_HOME": ""]).line == "codex home: /scratch/home/.codex (~/.codex)")
    }

    @Test(arguments: [true, false])
    func withoutTheFlagTheHomeComesFromTheInjectedEnvironmentNeverThisProcesss(setsCodexHome: Bool) throws {
        let scratch = try TemporaryDirectory.make("codex-environment")
        let binary = try CursorInstallHookTests.binary(in: scratch)
        let expected = scratch.appendingPathComponent(setsCodexHome ? "codex-home" : ".codex")
        if setsCodexHome {
            try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        }
        var environment = ["PATH": "/usr/bin:/bin", "CFFIXED_USER_HOME": scratch.path]
        environment["CODEX_HOME"] = setsCodexHome ? expected.path : nil
        let codex = FakeCodex()

        let printed = try Self.install([], binary: binary, codex: codex, environment: environment)
        let removed = try Self.uninstall(nil, codex: codex, environment: environment)

        #expect(Set(codex.calls.map(\.home)) == [expected.path])
        #expect(printed.hasPrefix("codex home: \(expected.path) (\(setsCodexHome ? "$CODEX_HOME" : "~/.codex"))"), "\(printed)")
        #expect(removed.contains("mcp: removed sift"), "\(removed)")
        #expect(FileManager.default.fileExists(atPath: expected.appendingPathComponent("hooks.json").path))
    }

    @Test
    func siftUninstallTakesOutTheCodexRegistrationAndSaysNothingWhenThereIsNone() throws {
        let installed = try UninstallCommandTests.install()
        let binary = try CursorInstallHookTests.binary(in: installed.home)
        let home = try Self.codexHome(in: installed.home, named: ".codex", hooks: Self.foreignHooks)
        let foreign = try Data(contentsOf: home.appendingPathComponent("hooks.json"))
        let codex = FakeCodex()
        try Self.install([], binary: binary, codex: codex, environment: installed.environment)

        let lines = try Self.siftUninstall(installed, codex: codex)
        let again = try Self.siftUninstall(installed, codex: codex)

        #expect(lines.contains("mcp: removed sift — \(binary.path) mcp"), "\(lines)")
        #expect(lines.contains("hooks: removed SessionStart — \(binary.path) session-start"), "\(lines)")
        #expect(try Data(contentsOf: home.appendingPathComponent("hooks.json")) == foreign)
        // The backup the first run wrote stays listed until a purge, as the settings backup does; nothing else names Codex.
        let backup = "backup: \(home.appendingPathComponent("hooks.json.bak-sift").path) — a copy of the Codex hooks from before sift last rewrote them; `sift uninstall --purge` deletes it"
        #expect(again.contains(backup), "\(again)")
        #expect(!again.contains { ($0.contains("codex") && $0 != backup) || $0.hasPrefix("hooks: removed") }, "\(again)")
        #expect(codex.server == nil)
    }
}

extension CodexInstallHookTests {
    /// A Codex home under `root` holding `hooks`, serialized as the install writes it, so an uninstall that restores it compares byte for byte.
    static func codexHome(in root: URL, named name: String = "codex-home", hooks: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = try #require(JSONSerialization.jsonObject(with: Data(hooks.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        try CursorConfigJSON.encode(object).write(to: directory.appendingPathComponent("hooks.json"))
        return directory
    }

    /// Runs `install-hook --agent codex` with `arguments` as the binary at `binary`, returning what it printed.
    @discardableResult
    static func install(_ arguments: [String], binary: URL, codex: FakeCodex, environment: [String: String]? = nil) throws -> String {
        var command = try InstallHookCommand.parse(["--agent", "codex"] + arguments)
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.arguments = [binary.path, "install-hook"]
        command.environment = environment ?? ["PATH": "/usr/bin:/bin", "CFFIXED_USER_HOME": binary.deletingLastPathComponent().path]
        command.executable = binary.path
        command.codex = codex
        try command.run()
        return recorded.printed
    }

    /// Runs `uninstall-hook --agent codex`, against `home` or else the one `environment` names, returning what it printed.
    @discardableResult
    static func uninstall(_ home: URL?, codex: FakeCodex, environment: [String: String] = [:]) throws -> String {
        var command = try UninstallHookCommand.parse(["--agent", "codex"] + (home.map { ["--codex-dir", $0.path] } ?? []))
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.environment = environment
        command.codex = codex
        try command.run()
        return recorded.printed
    }

    /// Runs `sift uninstall` over `installed`'s scratch home with `codex` as the only `codex` there is.
    static func siftUninstall(_ installed: UninstallCommandTests.Installed, codex: FakeCodex) throws -> [String] {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment
        command.output = recorded.output
        let remover = UninstallCommandTests.ServerRemover()
        let config = installed.claudeConfig
        command.removeServer = { _, scope in remover.remove(from: config, scope: scope) }
        command.codex = codex
        try command.run()
        return recorded.printed.split(separator: "\n").map(String.init)
    }
}
