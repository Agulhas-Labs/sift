//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// `sift install` with nobody to ask leaves the allow rules out and its Claude Code section says so, naming the `install-hook` flags that add them; `InstallConsentSplitTests` covers the questions asked at a terminal.
@Suite(.temporaryDirectories)
struct InstallCommandAllowRunLineTests {
    @Test
    func anInstallIntoClaudeCodeWithNoTerminalNamesTheFlagsThatAddTheAllowRules() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--yes"])

        #expect(run.status == 0)
        #expect(run.lines.contains { $0.hasPrefix("  Claude Code: installed — wrote ") })
        #expect(run.lines.contains { $0.hasPrefix("  permissions: nothing added") })
        #expect(run.printed.contains("sift install-hook --allow-run"))
        #expect(run.printed.contains("sift install-hook --allow-lookups"))
    }
}
