//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// `--purge` deletes the `.bak-sift` backups the uninstall lists as well as the `.sift/` directories, so its help says both.
struct UninstallPurgeHelpTests {
    /// The flag's own help, the line a reader deciding whether to pass it sees, names the backups and whose they are.
    @Test
    func thePurgeHelpNamesTheBackupsItDeletes() {
        let help = UninstallCommand.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(help.contains("Also delete every listed .sift/ directory"), "\(help)")
        #expect(help.contains("every listed *.bak-sift backup (of settings.json, Cursor's mcp.json and hooks.json, and Codex's hooks.json)"), "\(help)")
    }
}
