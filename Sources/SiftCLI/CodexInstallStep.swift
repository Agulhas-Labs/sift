//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Codex step of `sift install`: the hooks in the Codex home and the server through `codex mcp`, through the same installer as `install-hook --agent codex`, without its exit.
struct CodexInstallStep {
    /// Installs `binary` into the Codex home `environment` names, printing to `output`.
    static func run(binary: String, environment: [String: String], runner: any CodexMcpRunner, output: CommandOutput) throws -> InstallStepReport {
        let home = CodexInstall.home(flag: nil, environment: environment)
        let outcome = try CodexHookInstaller.installing(home: home, binary: binary, runner: runner, output: output)
        // `codex mcp add` writes config.toml itself, so a registration is a change the written files do not show.
        let registered = outcome.lines.contains { $0.hasPrefix("mcp: registered") || $0.hasPrefix("mcp: replaced") }
        return InstallStepReport(agent: .codex, written: outcome.written, registered: registered, failures: outcome.failures)
    }
}
