//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `install-hook` refuses a settings file that is there and cannot be read, rather than reading it as empty and replacing it with sift's hooks alone.
@Suite(.temporaryDirectories)
struct InstallHookUnreadableSettingsTests {
    @Test
    func anUnreadableSettingsFileIsRefusedAndLeftAsItWas() throws {
        let settings = try TemporaryDirectory.make("unreadable-settings").appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        var command = try InstallHookCommand.parse(["--settings", settings.path, "--no-allow-run"])
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.environment = ["HOME": settings.deletingLastPathComponent().path]

        #expect(throws: CursorInstall.Refused.self) { try command.install() }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == original)
        #expect(PathKind.of(SettingsBackupFile.url(beside: settings)) == .absent)
        #expect(recorded.printed.isEmpty)
    }
}
