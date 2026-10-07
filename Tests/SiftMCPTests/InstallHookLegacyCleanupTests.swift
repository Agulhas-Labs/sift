//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Sift draws nothing always on screen, so `install-hook` registers no status line and takes out the status line and band an older install left, touching nothing of anyone else's.
@Suite(.temporaryDirectories)
struct InstallHookLegacyCleanupTests {
    typealias FakeClaude = UninstallBandTests.FakeClaudePlugin

    private static var removedLine: String {
        "statusline: removed (sift no longer draws one; run sift report)"
    }

    /// A re-run over hooks that are already current still takes out the status line an older install registered, and says so.
    @Test
    func aSiftStatusLineIsRemovedWhenTheHooksAreAlreadyCurrent() throws {
        let home = try TemporaryDirectory.make("legacy-statusline")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try Self.install(home: home)
        try LegacyStatusLine.adding(command: "/bin/sift statusline", to: Data(contentsOf: settings)).write(to: settings)

        let printed = try Self.install(home: home)

        #expect(try Self.object(at: settings)["statusLine"] == nil)
        #expect(printed.contains(Self.removedLine), "\(printed)")
    }

    @Test
    func aForeignStatusLineIsLeftAloneAndUnmentioned() throws {
        let home = try TemporaryDirectory.make("legacy-statusline-foreign")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LegacyStatusLine.adding(command: "~/.claude/my-statusline.sh", to: nil).write(to: settings)

        let printed = try Self.install(home: home)

        #expect(try (Self.object(at: settings)["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/my-statusline.sh")
        #expect(!printed.contains("statusline:"), "\(printed)")
    }

    @Test
    func aFreshInstallWritesNoStatusLine() throws {
        let home = try TemporaryDirectory.make("legacy-statusline-fresh")
        let settings = home.appendingPathComponent(".claude/settings.json")

        let printed = try Self.install(home: home)
        let object = try Self.object(at: settings)

        #expect(object["hooks"] != nil)
        #expect(object["statusLine"] == nil)
        #expect(!printed.contains("statusline:"), "\(printed)")
    }

    @Test
    func theBandIsTakenOutThroughClaudeWhereTheSettingsNameIt() throws {
        let home = try TemporaryDirectory.make("legacy-band")
        let settings = try Self.settingsNamingTheBand(home: home)
        let claude = FakeClaude(settings: settings)

        let printed = try Self.install(home: home, claude: claude)

        #expect(claude.calls == [["plugin", "uninstall", "sift-band@sift", "--scope", "user"], ["plugin", "marketplace", "remove", "sift", "--scope", "user"]])
        #expect(printed.contains("band: uninstalled the Claude Code plugin sift-band@sift"), "\(printed)")
        #expect(printed.contains("band: removed the Claude Code plugin marketplace sift"), "\(printed)")
        let object = try Self.object(at: settings)
        #expect((object["enabledPlugins"] as? [String: Any])?["sift-band@sift"] == nil)
        #expect(object["hooks"] != nil)
    }

    @Test
    func withoutTheBandInTheSettingsClaudeIsNeverRun() throws {
        let home = try TemporaryDirectory.make("legacy-band-absent")
        let settings = home.appendingPathComponent(".claude/settings.json")
        let claude = FakeClaude(settings: settings)

        let printed = try Self.install(home: home, claude: claude)

        #expect(claude.calls.isEmpty)
        #expect(!printed.contains("band:"), "\(printed)")
    }

    /// A named settings file is not the one `claude plugin` edits, so the band step is skipped there, as the uninstall skips it.
    @Test
    func aNamedSettingsFileSkipsTheBand() throws {
        let home = try TemporaryDirectory.make("legacy-band-named")
        let settings = try Self.settingsNamingTheBand(home: home)
        let claude = FakeClaude(settings: settings)

        let printed = try Self.install(home: home, claude: claude, named: settings)

        #expect(claude.calls.isEmpty)
        #expect(!printed.contains("band:"), "\(printed)")
        #expect(try (Self.object(at: settings)["enabledPlugins"] as? [String: Any])?["sift-band@sift"] != nil)
    }

    @Test(arguments: [SiftUninstall.PluginRun.noClaude, .failed("Plugin not found")])
    func aMissingOrFailingClaudeLeavesTheInstallGreenWithTheCommandsToRun(result: SiftUninstall.PluginRun) throws {
        let home = try TemporaryDirectory.make("legacy-band-failing")
        let settings = try Self.settingsNamingTheBand(home: home)
        let claude = FakeClaude(settings: settings, result: result)

        let printed = try Self.install(home: home, claude: claude)

        #expect(printed.contains("hook: registered for SessionStart"), "\(printed)")
        #expect(printed.contains("band: not removed"), "\(printed)")
        #expect(printed.contains("claude plugin marketplace remove sift --scope user"), "\(printed)")
        #expect(try Self.object(at: settings)["hooks"] != nil)
    }
}

private extension InstallHookLegacyCleanupTests {
    /// Runs `install-hook` under `home` with `claude` faked and no allow rules, against the settings the home holds or the file `named`, and returns what it printed.
    @discardableResult
    static func install(home: URL, claude: FakeClaude? = nil, named: URL? = nil) throws -> String {
        var command = try InstallHookCommand.parse(named.map { ["--settings", $0.path, "--no-allow-run"] } ?? ["--no-allow-run"])
        command.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "PATH": "/usr/bin:/bin"]
        command.arguments = ["/bin/sift", "install-hook"]
        command.executable = "/bin/sift"
        command.stateDirectory = home.appendingPathComponent(".sift")
        let fake = claude ?? FakeClaude(settings: home.appendingPathComponent(".claude/settings.json"), result: .noClaude)
        command.runPlugin = { _, arguments in fake.run(arguments) }
        let recorded = RecordedOutput()
        command.output = recorded.output
        try command.run()
        return recorded.printed
    }

    /// The settings under `home` with the band enabled from a local `sift` marketplace, as an older `install.sh` left them.
    static func settingsNamingTheBand(home: URL) throws -> URL {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = [
            "enabledPlugins": ["sift-band@sift": true],
            "extraKnownMarketplaces": ["sift": ["source": ["source": "directory", "path": home.appendingPathComponent(".local/share/sift").path]]],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
        return settings
    }

    static func object(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
    }
}
