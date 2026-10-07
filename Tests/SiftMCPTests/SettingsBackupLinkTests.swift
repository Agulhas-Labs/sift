//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `install-hook`, `uninstall-hook` and `uninstall` each keep a copy of the settings beside them before a rewrite; a symlink at that path is named, never written through, so the file it points to keeps its bytes.
@Suite(.temporaryDirectories)
struct SettingsBackupLinkTests {
    /// A settings file beside a `.bak-sift` that links to `kept.json`, which holds `kept`.
    private static func linkedBackup(_ settings: URL) throws -> (backup: URL, target: URL) {
        let target = settings.deletingLastPathComponent().appendingPathComponent("kept.json")
        try "kept".write(to: target, atomically: true, encoding: .utf8)
        let backup = settings.appendingPathExtension("bak-sift")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: target)
        return (backup, target)
    }

    private static func installHook(_ settings: URL) throws -> String {
        var command = try InstallHookCommand.parse(["--settings", settings.path, "--no-allow-run"])
        let recorded = RecordedOutput()
        command.output = recorded.output
        try command.run()
        return recorded.printed
    }

    @Test
    func installHookNamesALinkedBackupAndLeavesWhatItPointsTo() throws {
        let settings = try TemporaryDirectory.make("backup-link").appendingPathComponent("settings.json")
        try #"{"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let (backup, target) = try Self.linkedBackup(settings)

        let printed = try Self.installHook(settings)

        #expect(try String(contentsOf: target, encoding: .utf8) == "kept")
        #expect(PathKind.of(backup) == .symlink(target.path))
        #expect(printed.contains("backup: not written — \(backup.path) is a symlink to \(target.path), not a file, and nothing is written through it"), "\(printed)")
    }

    @Test
    func uninstallHookLeavesWhatALinkedBackupPointsTo() throws {
        let settings = try TemporaryDirectory.make("backup-link").appendingPathComponent("settings.json")
        var current = Data(#"{"theme":"dark"}"#.utf8)
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers
            ).data
        }
        try current.write(to: settings)
        let (backup, target) = try Self.linkedBackup(settings)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(try String(contentsOf: target, encoding: .utf8) == "kept")
        #expect(PathKind.of(backup) == .symlink(target.path))
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(remaining["hooks"] == nil)
    }

    @Test
    func uninstallNamesALinkedBackupAndLeavesWhatItPointsTo() throws {
        let installed = try UninstallCommandTests.install()
        let (backup, target) = try Self.linkedBackup(installed.settings)

        let lines = try UninstallCommandTests.uninstall(installed, remover: UninstallCommandTests.ServerRemover())

        #expect(try String(contentsOf: target, encoding: .utf8) == "kept")
        #expect(PathKind.of(backup) == .symlink(target.path))
        #expect(lines.contains("backup: not written — \(backup.path) is a symlink to \(target.path), not a file, and nothing is written through it"), "\(lines)")
    }
}
