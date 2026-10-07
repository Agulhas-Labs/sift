//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// An agent whose install throws says why under its own header, not only in the summary at the end.
@Suite(.temporaryDirectories)
struct InstallCommandFailedSectionTests {
    @Test
    func aThrownFailureIsSaidUnderItsAgentsHeader() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"], directories: [".claude"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }

        let run = try machine.run(["--agent", "claude"])

        #expect(run.status == 1)
        let header = try #require(run.lines.firstIndex(of: "Claude Code:"))
        let section = run.lines.dropFirst(header + 1).prefix { $0.hasPrefix("  ") }
        #expect(section.contains { $0.hasPrefix("  claude: nothing written — \(settings.path) could not be read") }, "\(run.printed)")
        #expect(run.lines.contains { $0.hasPrefix("  Claude Code: failed — claude: nothing written — \(settings.path) could not be read") })
    }
}
