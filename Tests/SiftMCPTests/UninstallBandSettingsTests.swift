//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The answer to `sift uninstall --settings P` says the band step was skipped, since it is not a step that failed or found nothing.
@Suite(.temporaryDirectories)
struct UninstallBandSettingsTests {
    @Test
    func aSettingsFileNamedOnTheCommandLineIsAnsweredWithTheSkippedBandStep() throws {
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

        let skipped = recorded.printed.components(separatedBy: "\n").filter { $0.contains("band step was skipped") }

        #expect(skipped.count == 1, "\(recorded.printed)")
        #expect(skipped.first?.contains("--settings") == true, "\(recorded.printed)")
        #expect(claude.calls.isEmpty)
    }
}
