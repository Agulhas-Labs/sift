//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers what `uninstall-hook` does to the file itself — the backup, the atomic write, and the file it must never create — which the Core removal tests cannot see because they are a transform over bytes.
@Suite(.temporaryDirectories)
struct UninstallHookCommandTests {
    /// A settings file holding every hook and the status line an older install registered, as an uninstall finds it.
    private static func installedSettings(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("settings.json")
        var current: Data?
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers
            ).data
        }
        try LegacyStatusLine.adding(command: "/bin/sift statusline", to: current).write(to: url)
        return url
    }

    private static func settingsObject(
        at url: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }

    @Test
    func aWriteIsPrecededByABackupOfTheFileItRewrites() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = try Self.installedSettings(in: directory)
        let before = try Data(contentsOf: settings)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let backup = settings.appendingPathExtension("bak-sift")
        #expect(try Data(contentsOf: backup) == before)
        let remaining = try Self.settingsObject(at: settings)
        #expect(remaining["hooks"] == nil)
        #expect(remaining["statusLine"] == nil)
    }

    /// The backup exists to survive a merge bug, so it is written when something is rewritten and at no other time — a run that changed nothing must not spend the one copy the user has.
    @Test
    func nothingRegisteredMeansNothingWrittenAndNoBackup() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = directory.appendingPathComponent("settings.json")
        let foreign = #"{"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/protect.sh"}]}]}}"#
        try foreign.write(to: settings, atomically: true, encoding: .utf8)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(try String(contentsOf: settings, encoding: .utf8) == foreign)
        #expect(FileManager.default.fileExists(atPath: settings.appendingPathExtension("bak-sift").path) == false)
    }

    /// A file that is there and cannot be read was never looked into, so it fails rather than answering that nothing is registered.
    @Test
    func anUnreadableSettingsFileFailsRatherThanReadingAsEmpty() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = try Self.installedSettings(in: directory)
        let before = try Data(contentsOf: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }

        #expect(throws: (any Error).self) {
            try UninstallHookCommand.parse(["--settings", settings.path]).run()
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == before)
        #expect(FileManager.default.fileExists(atPath: settings.appendingPathExtension("bak-sift").path) == false)
    }

    /// A settings file that is not there registered nothing.
    ///
    /// An uninstall that created one to prove it had run would be leaving litter in the name of tidying up.
    @Test
    func anAbsentSettingsFileIsNotAnErrorAndIsNotCreated() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = directory.appendingPathComponent("settings.json")

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(FileManager.default.fileExists(atPath: settings.path) == false)
    }

    /// The switch for someone a week in who wants the shell nudges gone and everything else kept.
    @Test
    func onlyAdviceTakesThePreToolUseHookAndLeavesThePrimerAndStatusLine() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = try Self.installedSettings(in: directory)

        let command = try UninstallHookCommand.parse(["--settings", settings.path, "--only-advice"])
        #expect(command.onlyAdvice)
        try command.run()

        let remaining = try Self.settingsObject(at: settings)
        let hooks = try #require(remaining["hooks"] as? [String: Any])
        #expect(hooks["PreToolUse"] == nil)
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["SubagentStart"] != nil)
        #expect((remaining["statusLine"] as? [String: Any])?["command"] as? String == "/bin/sift statusline")
    }

    // MARK: - The pair's shared invariant

    /// The install must not be able to write a registration the uninstall cannot find again.
    ///
    /// Recognition is by shape, so a `--command` outside that shape installs a hook that is invisible to both the re-run path and the uninstall: the sweep reports itself clean while the primer keeps running, and the next install appends a second one beside it. Refused at validation, before a byte is written — which is what the settings file being absent afterwards pins.
    @Test
    func installRefusesACommandTheUninstallCouldNotFindAgain() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = directory.appendingPathComponent("settings.json")

        #expect(throws: (any Error).self) {
            let command = try InstallHookCommand.parse([
                "--settings", settings.path,
                "--command", "/usr/local/libexec/sift-primer.sh",
            ])
            try command.validate()
            try command.run()
        }

        #expect(FileManager.default.fileExists(atPath: settings.path) == false)
    }

    /// The refusal must not catch the case it exists to allow: a command at an unusual path that still names the binary and the subcommand.
    @Test
    func installAcceptsARecognisableCommandAtAnyPath() throws {
        let command = try InstallHookCommand.parse(["--command", "/opt/homebrew/bin/sift session-start"])

        try command.validate()

        #expect(HookRegistration.isOurs("/opt/homebrew/bin/sift session-start"))
    }

    /// Running it twice is the case a user is most likely to hit, having lost track of whether the first one took.
    @Test
    func aSecondRunLeavesTheFileByteForByteAsTheFirstOneLeftIt() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = try Self.installedSettings(in: directory)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()
        let afterFirst = try Data(contentsOf: settings)
        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(try Data(contentsOf: settings) == afterFirst)
    }

    // MARK: - The PostToolUse reuse nudge

    /// Installing twice leaves one `PostToolUse` entry, at the timeout and matcher the nudge is registered with, and a full uninstall takes it back out.
    ///
    /// Applied directly (as ``installedSettings(in:)`` above does), not through `InstallHookCommand.run()`: that would build the command from *this test binary's own path*, which names neither `sift` nor `post-tool-use`, so a second call could never recognise the first call's entry as its own — a property of driving the installer in-process, not of the merge this test is pinning.
    @Test
    func aPostToolUseEntryIsRegisteredOnceAndGoesOnUninstall() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = directory.appendingPathComponent("settings.json")
        let event = try #require(HookRegistration.events.first { $0.subcommand == "post-tool-use" })

        var current: Data?
        for _ in 0 ..< 2 {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try #require(current).write(to: settings)

        let hooks = try #require(Self.settingsObject(at: settings)["hooks"] as? [String: Any])
        let entries = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["matcher"] as? String == "Write|Edit|MultiEdit|mcp__sift__digest")
        let inner = try #require(entries.first?["hooks"] as? [[String: Any]])
        #expect(inner.count == 1)
        #expect(inner.first?["command"] as? String == "/bin/sift post-tool-use")
        #expect(inner.first?["timeout"] as? Int == 3)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let remaining = try Self.settingsObject(at: settings)
        #expect((remaining["hooks"] as? [String: Any])?["PostToolUse"] == nil)
    }

    /// A foreign `PostToolUse` entry the user had is left alone by both halves — the same promise the install already keeps for `PreToolUse`.
    @Test
    func aForeignPostToolUseEntryIsLeftAloneByInstallAndUninstall() throws {
        let directory = try TemporaryDirectory.make("uninstall-cmd")
        let settings = directory.appendingPathComponent("settings.json")
        let foreign = #"{"hooks":{"PostToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/protect.sh"}]}]}}"#
        let event = try #require(HookRegistration.events.first { $0.subcommand == "post-tool-use" })

        var current: Data? = foreign.data(using: .utf8)
        current = try HookRegistration.apply(
            to: current,
            command: "/bin/sift \(event.subcommand)",
            event: event.name,
            subcommand: event.subcommand,
            matchers: event.matchers,
            timeout: event.timeout
        ).data
        try #require(current).write(to: settings)

        var hooks = try #require(Self.settingsObject(at: settings)["hooks"] as? [String: Any])
        var entries = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries.contains { ($0["matcher"] as? String) == "Write" })

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        hooks = try #require(Self.settingsObject(at: settings)["hooks"] as? [String: Any])
        entries = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["matcher"] as? String == "Write")
    }
}
