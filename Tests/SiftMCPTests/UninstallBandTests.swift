//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The band plugin `install.sh` enables is taken out through `claude plugin`, and only where the settings file registers it.
@Suite(.temporaryDirectories)
struct UninstallBandTests {
    private typealias Fixture = UninstallCommandTests

    private static let uninstallCall = ["plugin", "uninstall", "sift-band@sift", "--scope", "user"]
    private static let marketplaceCall = ["plugin", "marketplace", "remove", "sift", "--scope", "user"]

    @Test
    func theBandAndItsMarketplaceAreTakenOutThroughClaudeAndTheRestOfTheSettingsStays() throws {
        let installed = try Self.install(enabled: true)
        let claude = FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls == [Self.uninstallCall, Self.marketplaceCall])
        #expect(lines.contains("band: uninstalled the Claude Code plugin sift-band@sift"), "\(lines)")
        #expect(lines.contains("band: removed the Claude Code plugin marketplace sift"), "\(lines)")
        #expect(status == 0)
        let settings = try Fixture.object(at: installed.settings)
        #expect((settings["enabledPlugins"] as? [String: Any])?["sift-band@sift"] == nil)
        #expect((settings["enabledPlugins"] as? [String: Any])?["other@elsewhere"] as? Bool == true)
        #expect((settings["extraKnownMarketplaces"] as? [String: Any])?["sift"] == nil)
        #expect((settings["extraKnownMarketplaces"] as? [String: Any])?["elsewhere"] != nil)
    }

    @Test
    func aDisabledBandIsStillInstalledSoItIsTakenOut() throws {
        let installed = try Self.install(enabled: false)
        let claude = FakeClaudePlugin(settings: installed.settings)

        let (lines, _) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls == [Self.uninstallCall, Self.marketplaceCall])
        #expect(lines.contains("band: uninstalled the Claude Code plugin sift-band@sift"), "\(lines)")
    }

    @Test
    func withoutABandRegisteredClaudeIsNeverRunAndTheAnswerSaysNothingOfIt() throws {
        let installed = try Fixture.install()
        let claude = FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls.isEmpty)
        #expect(lines.allSatisfy { !$0.hasPrefix("band:") }, "\(lines)")
        #expect(status == 0)
    }

    @Test
    func aFailedPluginUninstallIsCountedNamedWithItsReasonAndTheMarketplaceIsLeftForTheNextTry() throws {
        let installed = try Self.install(enabled: true)
        let claude = FakeClaudePlugin(settings: installed.settings, result: .failed("Plugin not found"))

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls == [Self.uninstallCall])
        #expect(lines.contains { $0.hasPrefix("band: not removed — `claude plugin uninstall sift-band@sift --scope user` failed: Plugin not found") }, "\(lines)")
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed") == true, "\(lines)")
        #expect(status == 1)
    }

    @Test
    func aSuccessThatLeavesTheBandInTheSettingsIsNotReportedRemoved() throws {
        let installed = try Self.install(enabled: true)
        let claude = FakeClaudePlugin(settings: installed.settings, edits: false)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(lines.contains { $0.hasPrefix("band: not removed — `claude plugin uninstall sift-band@sift --scope user` succeeded and") && $0.hasSuffix("still names sift-band@sift") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("band: uninstalled") }, "\(lines)")
        #expect(status == 1)
    }

    @Test
    func noClaudeOnPathNamesTheCommandsToRunByHand() throws {
        let installed = try Self.install(enabled: true)
        let claude = FakeClaudePlugin(settings: installed.settings, result: .noClaude)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(lines.contains("band: not removed — `claude` is not on PATH; run: claude plugin uninstall sift-band@sift --scope user && claude plugin marketplace remove sift --scope user"), "\(lines)")
        #expect(status == 1)
    }

    @Test
    func aMarketplaceNamedSiftThatIsNotALocalFolderIsLeftAlone() throws {
        let installed = try Self.install(enabled: true, marketplaceSource: ["source": "github", "repo": "someone/sift"])
        let claude = FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls == [Self.uninstallCall])
        #expect(lines.contains("band: the marketplace named sift is a github one, not the folder install.sh registers — left alone"), "\(lines)")
        #expect(status == 0)
    }

    @Test
    func aSecondRunHasNoBandLeftToTakeOut() throws {
        let installed = try Self.install(enabled: true)
        let claude = FakeClaudePlugin(settings: installed.settings)
        _ = try Self.uninstall(installed, claude: claude)

        let (lines, status) = try Self.uninstall(installed, claude: claude)

        #expect(claude.calls.count == 2)
        #expect(lines.first == "uninstall: nothing to do", "\(lines)")
        #expect(status == 0)
    }
}

extension UninstallBandTests {
    /// The uninstall fixture's home, with the band registered in its settings beside a plugin and a marketplace that are not sift's.
    static func install(enabled: Bool, marketplaceSource: [String: String] = ["source": "directory", "path": "/home/.local/share/sift"]) throws -> UninstallCommandTests.Installed {
        let installed = try UninstallCommandTests.install()
        var settings = try UninstallCommandTests.object(at: installed.settings)
        settings["enabledPlugins"] = ["sift-band@sift": enabled, "other@elsewhere": true]
        settings["extraKnownMarketplaces"] = [
            "sift": ["source": marketplaceSource],
            "elsewhere": ["source": ["source": "github", "repo": "someone/else"]],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: installed.settings)
        return installed
    }

    /// The uninstall command run under the scratch home with `claude` faked, and the status it exits with.
    static func uninstall(_ installed: UninstallCommandTests.Installed, claude: FakeClaudePlugin) throws -> (lines: [String], status: Int32) {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment
        command.output = recorded.output
        command.removeServer = { _, scope in UninstallCommandTests.ServerRemover().remove(from: installed.claudeConfig, scope: scope) }
        command.runPlugin = { _, arguments in claude.run(arguments) }
        var status: Int32 = 0
        do {
            try command.run()
        } catch let exit as ExitCode {
            status = exit.rawValue
        }
        return (recorded.printed.split(separator: "\n").map(String.init), status)
    }

    /// A `claude plugin` that records every call and, as the real one does, drops the plugin from `enabledPlugins` and the marketplace from `extraKnownMarketplaces` in the settings file it is given.
    final class FakeClaudePlugin: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private let settings: URL
        private let result: SiftUninstall.PluginRun
        private let edits: Bool

        init(settings: URL, result: SiftUninstall.PluginRun = .succeeded, edits: Bool = true) {
            self.settings = settings
            self.result = result
            self.edits = edits
        }

        var calls: [[String]] {
            lock.withLock { recorded }
        }

        func run(_ arguments: [String]) -> SiftUninstall.PluginRun {
            lock.withLock {
                recorded.append(arguments)
                guard result == .succeeded, edits,
                      var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any]
                else {
                    return result
                }
                if arguments.starts(with: ["plugin", "uninstall"]), arguments.count > 2 {
                    var plugins = object["enabledPlugins"] as? [String: Any] ?? [:]
                    plugins.removeValue(forKey: arguments[2])
                    object["enabledPlugins"] = plugins
                } else if arguments.starts(with: ["plugin", "marketplace", "remove"]), arguments.count > 3 {
                    var marketplaces = object["extraKnownMarketplaces"] as? [String: Any] ?? [:]
                    marketplaces.removeValue(forKey: arguments[3])
                    object["extraKnownMarketplaces"] = marketplaces
                }
                try? JSONSerialization.data(withJSONObject: object).write(to: settings)
                return result
            }
        }
    }
}
