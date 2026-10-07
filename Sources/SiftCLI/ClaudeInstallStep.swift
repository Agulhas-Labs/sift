//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Claude Code step of `sift install`: the hooks through `install-hook`, which also takes out an older install's status line and band, and asks about the allow rules where `prompt` has a terminal, then the MCP server through `claude mcp`, then the agent rule.
struct ClaudeInstallStep {
    /// The binary to install.
    let binary: String

    /// The environment whose home the Claude Code configuration is under.
    let environment: [String: String]

    /// How the binary was invoked, which `install-hook` resolves to ``binary`` again.
    let arguments: [String]

    /// This process's own executable, the other half of how the binary was invoked.
    let executable: String?

    /// Who runs `claude mcp`.
    let runner: any ClaudeMcpRunner

    /// Who answers the allow-rule questions, for the terminal or its absence.
    let prompt: AllowRunPrompt

    /// Installs ``binary`` into the Claude Code configuration, printing to `output`.
    func run(output: CommandOutput) throws -> InstallStepReport {
        // Not named with `--settings`: `install-hook` finds the same file through the environment set below, and only an
        // unnamed file is the user's own, the one `claude plugin` edits, so only then does it take out the legacy band.
        let settings = SiftPaths.claudeSettings(environment: environment)
        var hook = try InstallHookCommand.parse([])
        hook.output = output
        hook.prompt = prompt
        hook.arguments = arguments
        hook.environment = environment
        hook.executable = executable

        var report = InstallStepReport(agent: .claude)
        if try hook.install() {
            report.written.append(SettingsFile.named(settings))
        }
        let server = try ClaudeMcpInstall.install(config: SiftPaths.claudeConfig(environment: environment), binary: binary, runner: runner)
        emit(server, to: output)
        let rule = try ClaudeRuleInstall.install(source: ClaudeRuleInstall.source(forBinary: binary), destination: SiftPaths.claudeRule(environment: environment))
        emit(rule, to: output)
        report.written += server.written + rule.written
        report.registered = !server.written.isEmpty
        report.failures = server.failures + rule.failures
        return report
    }

    private func emit(_ outcome: CursorInstall.Outcome, to output: CommandOutput) {
        for line in outcome.lines + outcome.notes + outcome.failures {
            output.emit(line)
        }
    }
}
