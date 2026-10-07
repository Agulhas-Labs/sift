//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `claude plugin` edits the user's own settings, so `sift uninstall --settings P` never runs it against a copy.
@Suite(.temporaryDirectories)
struct UninstallBandSettingsOptionTests {
    @Test
    func aSettingsFileNamedOnTheCommandLineLeavesTheBandAlone() throws {
        let installed = try UninstallBandTests.install(enabled: true)
        let copy = installed.home.appendingPathComponent("copy-settings.json")
        try FileManager.default.copyItem(at: installed.settings, to: copy)
        let claude = UninstallBandTests.FakeClaudePlugin(settings: copy)

        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse(["--settings", copy.path])
        command.environment = installed.environment
        command.output = recorded.output
        command.removeServer = { _, scope in UninstallCommandTests.ServerRemover().remove(from: installed.claudeConfig, scope: scope) }
        command.runPlugin = { _, arguments in claude.run(arguments) }
        try command.run()

        #expect(claude.calls.isEmpty)
        #expect(!recorded.printed.contains("band:"), "\(recorded.printed)")
        let settings = try UninstallCommandTests.object(at: installed.settings)
        #expect((settings["enabledPlugins"] as? [String: Any])?["sift-band@sift"] != nil)
    }
}
