//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The marketplace half of the band step: a removal that fails, and one that succeeds without the settings file changing.
@Suite(.temporaryDirectories)
struct UninstallBandMarketplaceTests {
    @Test
    func aFailedMarketplaceRemovalIsCountedAndNamedWhileThePluginStaysReportedRemoved() throws {
        let installed = try UninstallBandTests.install(enabled: true)
        let claude = UninstallBandTests.FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed) { arguments in
            arguments.contains("marketplace") ? .failed("Marketplace not found") : claude.run(arguments)
        }

        #expect(lines.contains("band: uninstalled the Claude Code plugin sift-band@sift"), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("band: not removed — `claude plugin marketplace remove sift --scope user` failed: Marketplace not found") }, "\(lines)")
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed") == true, "\(lines)")
        #expect(status == 1)
    }

    @Test
    func aMarketplaceRemovalThatLeavesTheSettingsNamingItIsNotReportedRemoved() throws {
        let installed = try UninstallBandTests.install(enabled: true)
        let claude = UninstallBandTests.FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed) { arguments in
            arguments.contains("marketplace") ? .succeeded : claude.run(arguments)
        }

        #expect(lines.contains { $0.hasPrefix("band: not removed — `claude plugin marketplace remove sift --scope user` succeeded and") && $0.hasSuffix("still names the marketplace sift") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("band: removed the Claude Code plugin marketplace") }, "\(lines)")
        #expect(status == 1)
    }

    @Test
    func noClaudeOnPathForTheMarketplaceAloneNamesItsCommand() throws {
        let installed = try UninstallBandTests.install(enabled: true)
        let claude = UninstallBandTests.FakeClaudePlugin(settings: installed.settings)

        let (lines, status) = try Self.uninstall(installed) { arguments in
            arguments.contains("marketplace") ? .noClaude : claude.run(arguments)
        }

        #expect(lines.contains("band: not removed — `claude` is not on PATH; run: claude plugin marketplace remove sift --scope user"), "\(lines)")
        #expect(status == 1)
    }

    private static func uninstall(_ installed: UninstallCommandTests.Installed, plugin: @escaping @Sendable ([String]) -> SiftUninstall.PluginRun) throws -> (lines: [String], status: Int32) {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment
        command.output = recorded.output
        command.removeServer = { _, scope in UninstallCommandTests.ServerRemover().remove(from: installed.claudeConfig, scope: scope) }
        command.runPlugin = { _, arguments in plugin(arguments) }
        var status: Int32 = 0
        do {
            try command.run()
        } catch let exit as ExitCode {
            status = exit.rawValue
        }
        return (recorded.printed.split(separator: "\n").map(String.init), status)
    }
}
