//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `install-hook --agent cursor` and `uninstall-hook --agent cursor` end to end against a scratch Cursor directory: both files written in the registered shapes, re-runs that change nothing, foreign entries surviving both directions, a symlinked file written through, and an unreadable one refused before either file is touched.
@Suite(.temporaryDirectories)
struct CursorInstallHookTests {
    private static var foreignServers: String {
        #"{"mcpServers":{"notes":{"args":["serve"],"command":"/opt/notes/bin/notes"}}}"#
    }

    private static var foreignHooks: String {
        #"{"hooks":{"preToolUse":[{"command":"/usr/local/bin/audit-log.sh"}]},"version":1}"#
    }

    @Test
    func theInstallWritesBothFilesAndSaysWhatCursorDoesNotGet() throws {
        let scratch = try TemporaryDirectory.make("cursor-install")
        let binary = try Self.binary(in: scratch, at: "My Tools/sift")
        let cursor = scratch.appendingPathComponent(".cursor")

        let printed = try Self.install(cursor, binary: binary)

        let server = try #require(Self.object(at: cursor.appendingPathComponent("mcp.json"))["mcpServers"] as? [String: Any])
        #expect(server["sift"] as? NSDictionary == ["command": binary.path, "args": ["mcp"]] as NSDictionary)
        let hooks = try #require(Self.object(at: cursor.appendingPathComponent("hooks.json"))["hooks"] as? [String: Any])
        #expect((hooks["preToolUse"] as? [[String: String]])?.first == ["command": "'\(binary.path)' pre-tool-use --agent cursor"])
        #expect(printed.contains("mcp: registered sift — \(binary.path) mcp\n"), "\(printed)")
        #expect(printed.contains("hooks: registered sessionStart — '\(binary.path)' session-start --agent cursor\n"), "\(printed)")
        #expect(printed.contains("restart Cursor"), "\(printed)")
        for line in CursorInstall.unsupported + [CursorHookInstaller.experimental] {
            #expect(printed.contains(line + "\n"), "\(printed)")
        }
    }

    @Test
    func aSecondInstallWritesNothingAndTheUninstallRestoresTheForeignFiles() throws {
        let scratch = try TemporaryDirectory.make("cursor-idempotent")
        let binary = try Self.binary(in: scratch)
        let cursor = try Self.cursorDirectory(in: scratch, servers: Self.foreignServers, hooks: Self.foreignHooks)
        let (mcp, hooksFile) = (cursor.appendingPathComponent("mcp.json"), cursor.appendingPathComponent("hooks.json"))
        let (foreignMcp, foreignHooks) = try (Data(contentsOf: mcp), Data(contentsOf: hooksFile))

        try Self.install(cursor, binary: binary)
        #expect(try Data(contentsOf: mcp.appendingPathExtension("bak-sift")) == foreignMcp)
        #expect(try (Self.object(at: mcp)["mcpServers"] as? [String: Any])?["notes"] != nil)
        #expect(try ((Self.object(at: hooksFile)["hooks"] as? [String: Any])?["preToolUse"] as? [Any])?.count == 2)
        let installed = try (Data(contentsOf: mcp), Data(contentsOf: hooksFile))
        for file in [mcp, hooksFile] {
            try FileManager.default.removeItem(at: file.appendingPathExtension("bak-sift"))
        }

        let again = try Self.install(cursor, binary: binary)

        #expect(try (Data(contentsOf: mcp), Data(contentsOf: hooksFile)) == installed)
        #expect(!FileManager.default.fileExists(atPath: mcp.appendingPathExtension("bak-sift").path))
        #expect(again.contains("mcp: already registered"), "\(again)")
        #expect(again.contains("hooks: already registered"), "\(again)")
        #expect(!again.contains("restart Cursor"), "\(again)")

        let removed = try Self.uninstall(cursor)

        #expect(removed.contains("hooks: removed preToolUse — \(binary.path) pre-tool-use --agent cursor"), "\(removed)")
        #expect(try (Data(contentsOf: mcp), Data(contentsOf: hooksFile)) == (foreignMcp, foreignHooks))
        let removedAgain = try Self.uninstall(cursor)
        #expect(removedAgain.contains("cursor: nothing registered"), "\(removedAgain)")
        #expect(try (Data(contentsOf: mcp), Data(contentsOf: hooksFile)) == (foreignMcp, foreignHooks))
    }

    @Test
    func aServerNamedSiftOfAnotherShapeIsReportedAndLeftAloneWhileTheHooksGoIn() throws {
        let scratch = try TemporaryDirectory.make("cursor-foreign-server")
        let binary = try Self.binary(in: scratch)
        let servers = #"{"mcpServers":{"sift":{"args":["-y","sift","mcp"],"command":"npx"}}}"#
        let cursor = try Self.cursorDirectory(in: scratch, servers: servers, hooks: nil)
        let before = try Data(contentsOf: cursor.appendingPathComponent("mcp.json"))

        let printed = try Self.install(cursor, binary: binary)

        #expect(printed.contains("mcp: left alone — a server named sift runs something else (npx -y sift mcp)"), "\(printed)")
        #expect(try Data(contentsOf: cursor.appendingPathComponent("mcp.json")) == before)
        #expect(FileManager.default.fileExists(atPath: cursor.appendingPathComponent("hooks.json").path))
        let removed = try Self.uninstall(cursor)
        #expect(removed.contains("mcp: not ours, left alone"), "\(removed)")
        #expect(try Data(contentsOf: cursor.appendingPathComponent("mcp.json")) == before)
    }

    @Test
    func symlinkedFilesAreWrittenThroughAndStayLinks() throws {
        let scratch = try TemporaryDirectory.make("cursor-symlink")
        let binary = try Self.binary(in: scratch)
        let dotfiles = try Self.cursorDirectory(in: scratch, named: "dotfiles", servers: Self.foreignServers, hooks: Self.foreignHooks)
        let cursor = scratch.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        for name in ["mcp.json", "hooks.json"] {
            try FileManager.default.createSymbolicLink(atPath: cursor.appendingPathComponent(name).path, withDestinationPath: "../dotfiles/\(name)")
        }

        let printed = try Self.install(cursor, binary: binary)

        for name in ["mcp.json", "hooks.json"] {
            #expect(PathKind.of(cursor.appendingPathComponent(name)) == .symlink("../dotfiles/\(name)"))
            #expect(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("\(name).bak-sift").path), "\(name)")
            #expect(!FileManager.default.fileExists(atPath: cursor.appendingPathComponent("\(name).bak-sift").path), "\(name)")
        }

        #expect(try (Self.object(at: dotfiles.appendingPathComponent("mcp.json"))["mcpServers"] as? [String: Any])?["sift"] != nil)
        #expect(printed.contains("\(cursor.path)/mcp.json → "), "\(printed)")
    }

    @Test
    func anUnreadableFileIsRefusedAndNeitherFileIsWritten() throws {
        let scratch = try TemporaryDirectory.make("cursor-unreadable")
        let binary = try Self.binary(in: scratch)
        let cursor = try Self.cursorDirectory(in: scratch, servers: Self.foreignServers, hooks: Self.foreignHooks)
        let mcp = cursor.appendingPathComponent("mcp.json")
        let hooksBefore = try Data(contentsOf: cursor.appendingPathComponent("hooks.json"))
        let mcpBefore = try Data(contentsOf: mcp)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mcp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mcp.path) }

        #expect(throws: CursorInstall.Refused.self) { try Self.install(cursor, binary: binary) }
        #expect(throws: CursorInstall.Refused.self) { try Self.uninstall(cursor) }

        #expect(try Data(contentsOf: cursor.appendingPathComponent("hooks.json")) == hooksBefore)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mcp.path)
        #expect(try Data(contentsOf: mcp) == mcpBefore)
        #expect(!FileManager.default.fileExists(atPath: mcp.appendingPathExtension("bak-sift").path))
    }

    @Test
    func aLinkThatLeadsNowhereIsRefusedNamingTheCursorDirectoryFlag() throws {
        let scratch = try TemporaryDirectory.make("cursor-dangling")
        let binary = try Self.binary(in: scratch)
        let cursor = scratch.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: cursor.appendingPathComponent("hooks.json").path, withDestinationPath: "../nowhere/hooks.json")

        let error = try #require(throws: CursorInstall.Refused.self) { try Self.install(cursor, binary: binary) }

        #expect(error.description.contains("--cursor-dir"), "\(error)")
        #expect(!FileManager.default.fileExists(atPath: cursor.appendingPathComponent("mcp.json").path))
    }

    @Test(arguments: [
        ["--agent", "cursor", "--settings", "/tmp/settings.json"],
        ["--agent", "cursor", "--no-allow-run"],
        ["--cursor-dir", "/tmp/cursor"],
    ])
    func aFlagTheAgentHasNoUseForIsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try InstallHookCommand.parse(arguments) }
    }

    @Test
    func anUninstallFlagForClaudeCodeIsRefusedWithCursor() {
        #expect(throws: (any Error).self) { try UninstallHookCommand.parse(["--agent", "cursor", "--only-advice"]) }
        #expect(throws: (any Error).self) { try UninstallHookCommand.parse(["--cursor-dir", "/tmp/cursor"]) }
    }

    @Test
    func siftUninstallAlsoTakesOutTheCursorRegistration() throws {
        let installed = try UninstallCommandTests.install()
        let binary = try Self.binary(in: installed.home)
        let cursor = try Self.cursorDirectory(in: installed.home, servers: Self.foreignServers, hooks: Self.foreignHooks)
        let foreign = try (Data(contentsOf: cursor.appendingPathComponent("mcp.json")), Data(contentsOf: cursor.appendingPathComponent("hooks.json")))
        try Self.install(cursor, binary: binary)

        let lines = try UninstallCommandTests.uninstall(installed, remover: UninstallCommandTests.ServerRemover())

        #expect(lines.contains("mcp: removed sift — \(binary.path) mcp"), "\(lines)")
        #expect(lines.contains("hooks: removed sessionStart — \(binary.path) session-start --agent cursor"), "\(lines)")
        #expect(try (Data(contentsOf: cursor.appendingPathComponent("mcp.json")), Data(contentsOf: cursor.appendingPathComponent("hooks.json"))) == foreign)
    }
}

extension CursorInstallHookTests {
    /// An executable `sift` at `relative` under `root`, the file the install is told is running.
    static func binary(in root: URL, at relative: String = "bin/sift") throws -> URL {
        try InstallHookBinaryPathTests.executable(at: relative, in: root)
    }

    /// A Cursor directory under `root` holding the given files, each serialized as the install writes one, so an uninstall that restores it compares byte for byte.
    static func cursorDirectory(
        in root: URL,
        named name: String = ".cursor",
        servers: String?,
        hooks: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (text, file) in [(servers, "mcp.json"), (hooks, "hooks.json")] {
            guard let text else { continue }
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], sourceLocation: sourceLocation)
            try CursorConfigJSON.encode(object).write(to: directory.appendingPathComponent(file))
        }
        return directory
    }

    /// Runs `install-hook --agent cursor` against `directory` as the binary at `binary`, returning what it printed.
    @discardableResult
    static func install(_ directory: URL, binary: URL) throws -> String {
        var command = try InstallHookCommand.parse(["--agent", "cursor", "--cursor-dir", directory.path])
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.arguments = [binary.path, "install-hook"]
        command.environment = ["PATH": "/usr/bin:/bin", "CFFIXED_USER_HOME": directory.deletingLastPathComponent().path]
        command.executable = binary.path
        try command.run()
        return recorded.printed
    }

    /// Runs `uninstall-hook --agent cursor` against `directory`, returning what it printed.
    @discardableResult
    static func uninstall(_ directory: URL) throws -> String {
        var command = try UninstallHookCommand.parse(["--agent", "cursor", "--cursor-dir", directory.path])
        let recorded = RecordedOutput()
        command.output = recorded.output
        try command.run()
        return recorded.printed
    }

    static func object(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
    }
}
