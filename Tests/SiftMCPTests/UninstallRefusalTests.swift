//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// `sift uninstall` deletes on a stranger's machine, so everything it cannot vouch for is listed and left: a `.sift` that is a link, a server it did not register, a file it could not remove.
@Suite(.temporaryDirectories)
struct UninstallRefusalTests {
    private typealias Fixture = UninstallCommandTests

    @Test
    func aSymlinkedCacheIsRefusedAndWhatItPointsToKept() throws {
        let installed = try Fixture.install()
        let precious = installed.home.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let cache = SiftPaths.cache(in: installed.recorded)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: precious)

        let lines = try Fixture.uninstall(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("a.txt").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cache.path)) == precious.path)
        let refused = "not purged: \(Fixture.cachePath(of: installed.recorded)) is a symlink to \(precious.path), and this tool does not delete through a symlink — remove the link by hand"
        #expect(lines.contains(refused), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("purged: ") && $0.hasSuffix(Fixture.cachePath(of: installed.recorded)) } == false)
    }

    @Test
    func aSymlinkedSiftHomeIsRefusedRatherThanReportedPurged() throws {
        let installed = try Fixture.install()
        let target = installed.home.appendingPathComponent("sift-elsewhere")
        try FileManager.default.moveItem(at: installed.siftHome, to: target)
        try FileManager.default.createSymbolicLink(at: installed.siftHome, withDestinationURL: target)

        let (lines, status) = try Fixture.exiting(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(PathKind.of(installed.siftHome) == .symlink(target.path))
        let refused = "not purged: \(installed.siftHome.path) is a symlink to \(target.path), and this tool does not delete through a symlink — remove the link by hand"
        #expect(lines.contains(refused), "\(lines)")
        #expect(lines.contains("purged: \(installed.siftHome.path)") == false)
    }

    /// The home recorded as a repository names the same `~/.sift` entry, which is listed and counted once, link or not.
    @Test
    func aSymlinkedSiftHomeUnderARecordedHomeIsRefusedOnce() throws {
        let installed = try Fixture.install()
        let target = installed.home.appendingPathComponent("sift-elsewhere")
        try FileManager.default.moveItem(at: installed.siftHome, to: target)
        try FileManager.default.createSymbolicLink(at: installed.siftHome, withDestinationURL: target)
        let registry = try JSONSerialization.data(withJSONObject: ["roots": [CanonicalPath.of(installed.home.path), installed.recorded.path]])
        try registry.write(to: RootsRegistry.fileURL(in: installed.siftHome))

        let (lines, status) = try Fixture.exiting(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed, ") == true, "\(lines)")
        #expect(lines.count { $0.hasPrefix("not purged: ") && $0.contains("/.sift is a symlink to \(target.path)") } == 1, "\(lines)")
    }

    @Test
    func anUnparseableSettingsFileIsNamedAndCountedAndTheRestStillRuns() throws {
        let installed = try Fixture.install()
        try "{not json".write(to: installed.settings, atomically: true, encoding: .utf8)

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed, ") == true, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("hooks: not checked — \(installed.settings.path) could not be read as settings: ") }, "\(lines)")
        #expect(lines.contains("rule: removed \(installed.rule.path)"))
        #expect(lines.contains("mcp: removed the user-scope server — /bin/sift mcp"))
        #expect(try String(contentsOf: installed.settings, encoding: .utf8) == "{not json")
    }

    @Test
    func anUnreadableSettingsFileIsNamedAsNotCheckedRatherThanNothingRegistered() throws {
        let installed = try Fixture.install()
        let path = installed.settings.path
        let before = try Data(contentsOf: installed.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed, ") == true, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("hooks: not checked — \(path) could not be read: ") }, "\(lines)")
        #expect(lines.contains("mcp: removed the user-scope server — /bin/sift mcp"))
        #expect(PathKind.of(installed.settings.appendingPathExtension("bak-sift")) == .absent)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(try Data(contentsOf: installed.settings) == before)
    }

    @Test
    func anUnparseableClaudeConfigIsListedAsNotCheckedRatherThanNothingRegistered() throws {
        let installed = try Fixture.install()
        try "{broken".write(to: installed.claudeConfig, atomically: true, encoding: .utf8)
        let remover = Fixture.ServerRemover()

        let (lines, status) = try Fixture.exiting(installed, remover: remover)

        #expect(status == 1)
        #expect(remover.calls == 0)
        let note = "mcp: not checked — \(installed.claudeConfig.path) could not be read as a JSON object; if sift is registered there, run: claude mcp remove sift --scope user"
        #expect(lines.filter { $0.hasPrefix("mcp: ") } == [note], "\(lines)")
    }

    @Test
    func aServerWhosePathMerelyContainsTheNameNeverReachesTheRemover() throws {
        let installed = try Fixture.install(serverCommand: "/opt/siftscience/bin/mcp-server")
        let remover = Fixture.ServerRemover()

        let lines = try Fixture.uninstall(installed, remover: remover)

        #expect(remover.calls == 0)
        #expect(try (Fixture.object(at: installed.claudeConfig)["mcpServers"] as? [String: Any])?["sift"] != nil)
        #expect(lines.contains("mcp: the user-scope server named sift runs /opt/siftscience/bin/mcp-server mcp, not a registration sift recognises — left alone"))
    }

    @Test
    func theServerIsFoundInTheConfigDirectoryClaudeCodeWasPointedAt() throws {
        let installed = try Fixture.install()
        let configDirectory = installed.home.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = configDirectory.appendingPathComponent(".claude.json")
        try FileManager.default.moveItem(at: installed.claudeConfig, to: config)
        let remover = Fixture.ServerRemover()
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment.merging(["CLAUDE_CONFIG_DIR": configDirectory.path]) { $1 }
        command.output = recorded.output
        command.removeServer = { _, scope in remover.remove(from: config, scope: scope) }

        try command.run()

        #expect(remover.calls == 1)
        #expect(recorded.printed.contains("mcp: removed the user-scope server — /bin/sift mcp"))
    }

    @Test
    func aRuleThatCannotBeRemovedIsCountedAndTheRestStillRuns() throws {
        let installed = try Fixture.install()
        let rules = installed.rule.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rules.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rules.path) }

        let (lines, status) = try Fixture.exiting(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed, ") == true, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("rule: not removed — \(installed.rule.path): ") }, "\(lines)")
        #expect(lines.contains("purged: \(installed.siftHome.path)"))
        #expect(lines.last?.hasPrefix("binary: rm ") == true)
        #expect(FileManager.default.fileExists(atPath: installed.rule.path))
    }

    /// `claude` finds its config through HOME alone, so a child run under a scratch home named by `CFFIXED_USER_HOME` would edit the real one.
    @Test
    func theClaudeChildRunsUnderTheHomeTheUninstallResolved() throws {
        let scratch = try TemporaryDirectory.make("uninstall-claude")
        let bin = scratch.appendingPathComponent("bin")
        let home = scratch.appendingPathComponent("home")
        let decoy = scratch.appendingPathComponent("decoy")
        for directory in [bin, home, decoy] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let log = scratch.appendingPathComponent("claude.log")
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\necho \"$*\" > '\(log.path)'\necho \"HOME=$HOME\" >> '\(log.path)'\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let removal = UninstallCommand.claudeRemovesServer(environment: [
            "PATH": bin.path,
            "CFFIXED_USER_HOME": home.path,
            "HOME": decoy.path,
        ], scope: .user)

        #expect(removal == .removed)
        #expect(try String(contentsOf: log, encoding: .utf8) == "mcp remove sift --scope user\nHOME=\(home.path)\n")
    }
}
