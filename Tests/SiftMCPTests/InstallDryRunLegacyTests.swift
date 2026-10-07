//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift install --dry-run` names each legacy band piece the real install would remove, only where it is there.
@Suite(.temporaryDirectories)
struct InstallDryRunLegacyTests {
    private static var pluginLine: String {
        "band: would uninstall the Claude Code plugin sift-band@sift"
    }

    private static var marketplaceLine: String {
        "band: would remove the Claude Code plugin marketplace sift"
    }

    /// A scratch machine with `claude` on the PATH and `settings` written as the Claude Code settings file.
    private static func machine(settings: [String: Any]) throws -> InstallCommandHarness {
        let machine = try InstallCommandHarness(onPath: ["claude"])
        let url = SiftPaths.claudeSettings(environment: machine.environment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        return machine
    }

    @Test
    func aDryRunNamesTheBandPluginAndMarketplaceWhereTheSettingsRegisterThem() throws {
        let machine = try Self.machine(settings: [
            "enabledPlugins": ["sift-band@sift": true],
            "extraKnownMarketplaces": ["sift": ["source": ["source": "directory", "path": "/somewhere"]]],
        ])
        let before = try machine.files()

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(run.lines.contains(Self.pluginLine), "\(run.printed)")
        #expect(run.lines.contains(Self.marketplaceLine), "\(run.printed)")
        #expect(try machine.files() == before)
        #expect(machine.claude.calls.isEmpty)
    }

    @Test
    func aDryRunSaysNothingOfTheBandWhereTheSettingsHoldNone() throws {
        let machine = try Self.machine(settings: [
            "extraKnownMarketplaces": ["sift": ["source": ["source": "github", "repo": "someone/else"]]],
        ])

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(!run.printed.contains("band:"), "\(run.printed)")
    }

    @Test
    func aDryRunSaysNothingOfTheBandWhereThereAreNoSettings() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(!run.printed.contains("band:"), "\(run.printed)")
    }
}
